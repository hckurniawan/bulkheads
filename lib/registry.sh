# docklet — Docker Hub, the OCI registry `container` pulls images from.
#
# Registry layer. Everything here is plain HTTPS against hub.docker.com: **no function
# in this file may call `container`.** That separation is what let these helpers survive
# the removal of the Docker engine untouched — Docker Hub is the registry, not the
# engine. Keep it greppable: `grep -n "container " lib/registry.sh` should only ever
# match comments.

# Part of docklet's shared library; loaded by lib/common.sh. Source-only — this file
# defines functions and variables and executes nothing.
if [ -n "${_DOCKLET_REGISTRY_SH:-}" ]; then return 0; fi
_DOCKLET_REGISTRY_SH=1

# Resolve this part's own directory so it can pull in what it depends on, making it
# sourceable on its own (handy for testing a layer in isolation). $0 is the wrapper,
# not this file, so BASH_SOURCE is the only reliable handle.
: "${DOCKLET_LIB_DIR:=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
. "${DOCKLET_LIB_DIR}/core.sh"

# Checks whether the Docker Hub digest for an image differs from a known hash. Docker Hub
# here is the registry `container` pulls from; the Docker engine is not involved.
# Given an image name (e.g. "alpine:latest" or "library/alpine:3.20") and the current
# hash to compare against, it fetches the latest digest from Docker Hub and reports the
# result through two globals (it emits no logs, like registry_resolve_image):
#   - FETCHED_DIGEST: the digest fetched from Docker Hub (empty if the fetch failed).
#   - DIGEST_CHANGED: "true" when a digest was fetched and it differs from current_hash,
#     "false" otherwise (including when the fetch failed, so a network error never
#     spuriously signals a change).
# Returns 0 when the digest changed, non-zero otherwise — so callers can branch on either
# the return code or the globals. Network errors and missing digests return non-zero with
# DIGEST_CHANGED=false. Usage:
#   if registry_digest_changed "alpine:latest" "${stored_digest}"; then ... fi
registry_digest_changed() {
	local image current_hash repo tag hub_repo
	image="$1"
	current_hash="$2"
	repo="${image%:*}"
	tag="${image##*:}"
	[ "${tag}" = "${image}" ] && tag="latest"
	FETCHED_DIGEST=""
	DIGEST_CHANGED="false"

	# Docker Hub namespaces single-name official images under library/.
	case "${repo}" in
		*/*) hub_repo="${repo}" ;;
		*)   hub_repo="library/${repo}" ;;
	esac

	# A failed fetch (offline, rate-limited) shouldn't be read as a change — keep
	# DIGEST_CHANGED=false and return non-zero.
	FETCHED_DIGEST="$(curl -sf "https://hub.docker.com/v2/repositories/${hub_repo}/tags/${tag}" \
		| grep -o '"digest":"[^"]*"' | head -1 | cut -d'"' -f4)" || return 1
	[ -n "${FETCHED_DIGEST}" ] || return 1

	if [ "${FETCHED_DIGEST}" != "${current_hash}" ]; then
		DIGEST_CHANGED="true"
		return 0
	fi
	return 1
}

# For official-image wrappers, which pin a "major.minor" version tag and never rebuild,
# this resolves the tag to actually run. It emits no logs; instead it reports through
# two globals the caller can act on:
#   - RESOLVED_IMAGE: the image to run. A newer MINOR within the pinned major is adopted
#     automatically; a newer MAJOR is never adopted (it may carry breaking changes).
#   - IMAGE_MAJOR_AVAILABLE: the newest available version when a newer MAJOR exists than
#     the pinned one (empty otherwise), so the caller can prompt a manual pin bump.
# Docker Hub is queried at most once per STALENESS_PERIOD; between checks the last
# resolved tag is reused. Network errors and non-version tags leave the pin untouched.
# Usage:
#   registry_resolve_image "hashicorp/terraform:1.15"
#   container run ... "${RESOLVED_IMAGE}"
registry_resolve_image() {
	local image repo tag major checked_file resolved_file cached hub_repo tags versions newest_in_major newest_overall
	image="$1"
	repo="${image%:*}"
	tag="${image##*:}"
	RESOLVED_IMAGE="${image}"
	IMAGE_MAJOR_AVAILABLE=""

	# Only meaningful for numeric version tags (e.g. 1.15, 20.11.0); skip otherwise.
	case "${tag}" in
		*[!0-9.]* | "") return 0 ;;
	esac
	major="${tag%%.*}"

	checked_file="$(registry_cache_path "${image}" last-checked)"
	resolved_file="$(registry_cache_path "${image}" resolved)"

	# Throttle Docker Hub checks. Between checks, reuse the previously resolved tag —
	# but only when it's an upgrade within the currently pinned major, so a hand-bumped
	# pin always wins over a stale cache.
	if [ -f "${checked_file}" ] \
		&& [ "$(( $(date +%s) - $(cat "${checked_file}") ))" -le "${STALENESS_PERIOD}" ]; then
		if [ -f "${resolved_file}" ]; then
			cached="$(cat "${resolved_file}")"
			if [ "${cached%%.*}" = "${major}" ]; then
				RESOLVED_IMAGE="${repo}:$(printf '%s\n%s\n' "${tag}" "${cached}" | sort -V | tail -1)"
			fi
		fi
		return 0
	fi

	# Docker Hub namespaces single-name official images under library/.
	case "${repo}" in
		*/*) hub_repo="${repo}" ;;
		*)   hub_repo="library/${repo}" ;;
	esac

	# A failed fetch (offline, rate-limited) shouldn't disrupt the run — keep the pin.
	tags="$(curl -sf "https://hub.docker.com/v2/repositories/${hub_repo}/tags?page_size=100" \
		| grep -o '"name":"[^"]*"' | cut -d'"' -f4)" || return 0
	mkdir -p "${PERSISTENT_DATA_DIR}"
	date +%s > "${checked_file}"

	# Keep only pure version tags (e.g. 1.15, 1.15.7). `|| true` so "no matches" (grep
	# exit 1) doesn't trip the caller's `set -e`.
	versions="$(printf '%s\n' "${tags}" | grep -E '^[0-9]+(\.[0-9]+)*$' || true)"
	[ -n "${versions}" ] || return 0

	# Newer MINOR within the pinned major → adopt automatically.
	newest_in_major="$(printf '%s\n' "${versions}" | grep -E "^${major}(\.[0-9]+)*\$" | sort -V | tail -1)"
	if [ -n "${newest_in_major}" ]; then
		tag="$(printf '%s\n%s\n' "${tag}" "${newest_in_major}" | sort -V | tail -1)"
	fi
	printf '%s' "${tag}" > "${resolved_file}"
	RESOLVED_IMAGE="${repo}:${tag}"

	# Newer MAJOR → record it; never adopted automatically. The caller decides whether
	# to surface it (a new major may carry breaking changes).
	newest_overall="$(printf '%s\n' "${versions}" | sort -V | tail -1)"
	if [ "${newest_overall%%.*}" -gt "${major}" ]; then
		IMAGE_MAJOR_AVAILABLE="${newest_overall}"
	fi
}

# Prints the path of one of registry_resolve_image's cache files for an image's repo.
# <kind> is "last-checked" (epoch of the last Hub check) or "resolved" (the tag adopted).
# Usage:
#   registry_cache_path "hashicorp/terraform:1.15" resolved
registry_cache_path() {
	local repo slug
	if [ -z "$1" ] || [ -z "$2" ]; then
		log_error "registry_cache_path: usage: registry_cache_path <image> <kind>."
		exit 1
	fi
	repo="${1%:*}"
	slug="$(printf '%s' "${repo}" | tr '/:' '__')"
	printf '%s/.%s-%s' "${PERSISTENT_DATA_DIR}" "${slug}" "$2"
}

# Drops registry_resolve_image's cache for an image's repo, so the next resolve queries
# Docker Hub again instead of waiting out STALENESS_PERIOD. Usage:
#   registry_forget_resolved "hashicorp/terraform:1.15"
registry_forget_resolved() {
	if [ -z "$1" ]; then
		log_error "registry_forget_resolved: no image given."
		exit 1
	fi
	rm -f "$(registry_cache_path "$1" last-checked)" "$(registry_cache_path "$1" resolved)"
}
