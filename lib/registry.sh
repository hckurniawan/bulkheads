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
# result through two globals (it emits no logs):
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
