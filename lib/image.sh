# docklet — the image lifecycle: does an image exist, is it stale, build it, stamp it.
#
# Top layer, built on all three below it. `container image inspect` and `container image
# rm` are spelled here and nowhere else in the repo, so a wrapper never talks to the
# engine about images directly.

# Part of docklet's shared library; loaded by lib/common.sh. Source-only — this file
# defines functions and variables and executes nothing.
if [ -n "${_DOCKLET_IMAGE_SH:-}" ]; then return 0; fi
_DOCKLET_IMAGE_SH=1

# Resolve this part's own directory so it can pull in what it depends on, making it
# sourceable on its own (handy for testing a layer in isolation). $0 is the wrapper,
# not this file, so BASH_SOURCE is the only reliable handle.
: "${DOCKLET_LIB_DIR:=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
. "${DOCKLET_LIB_DIR}/core.sh"
. "${DOCKLET_LIB_DIR}/engine.sh"
. "${DOCKLET_LIB_DIR}/registry.sh"

# Slugifies an image reference into a filename-safe token ("docklet/yt-dlp" becomes
# "docklet_yt-dlp").
image_slug() {
	printf '%s' "$1" | tr '/:' '__'
}

# Prints the path of one of an image's state files under DOCKLET_SYSTEM_DIR. Kinds:
#   built        epoch of the last successful image_build of this tag
#   checked      epoch of the last Docker Hub check for this image's base
#   base-digest  the base digest this image was last built against
# Always keyed on the docklet image, never on the base — so two wrappers sharing a
# base each keep their own throttle and their own digest, and one wrapper rebuilding
# can't suppress the other's rebuild.
image_stamp_path() {
	mkdir -p "${DOCKLET_SYSTEM_DIR}"
	printf '%s/.%s.%s' "${DOCKLET_SYSTEM_DIR}" "$(image_slug "$1")" "$2"
}

# Returns 0 if an image's stamp is missing, unreadable, or older than <seconds>.
# A missing or corrupt stamp counts as stale, so the first run after this helper was
# introduced always acts rather than silently skipping.
image_stamp_stale() {
	local stamp recorded
	stamp="$(image_stamp_path "$1" "$2")"
	[ -f "${stamp}" ] || return 0

	recorded="$(cat "${stamp}" 2>/dev/null)"
	case "${recorded}" in
		"" | *[!0-9]*) return 0 ;;
	esac

	[ "$(( $(date +%s) - recorded ))" -gt "$3" ]
}

# Returns 0 if the named image is present locally. This is the one place
# `container image inspect` is spelled — every existence check goes through it.
image_exists() {
	if [ -z "$1" ]; then
		log_error "image_exists: no image given."
		exit 1
	fi
	container image inspect "$1" >/dev/null 2>&1
}

# Removes a local image. A missing image is success — that is the state we wanted.
# Returns non-zero only when the image exists and could not be removed, e.g. a running
# container still references it.
image_remove() {
	if [ -z "$1" ]; then
		log_error "image_remove: no image given."
		exit 1
	fi
	image_exists "$1" || return 0
	container image rm "$1" >/dev/null 2>&1
}

# Builds an image from a Dockerfile supplied on stdin:
#   image_build "${IMAGE}" [extra build flags...] <<-EOF
#   	FROM ...
#   EOF
# `container build -f -` (an inline Dockerfile on stdin) only landed in apple/container
# on 2025-11-18 (PR #827), so the heredoc is spooled to a real file and passed by path
# instead — that works on every version. The file lives outside the build context so it
# isn't synced into the builder, and is removed whether or not the build succeeds.
#
# On success it stamps the build time, which is what the "age" policy of
# image_needs_build reads back — no wrapper has to remember to record it.
image_build() {
	local tag dockerfile build_status
	if [ -z "$1" ]; then
		log_error "image_build: no tag given."
		exit 1
	fi
	tag="$1"
	shift

	mkdir -p "${DOCKLET_SYSTEM_DIR}"
	dockerfile="$(mktemp "${DOCKLET_SYSTEM_DIR}/Dockerfile.XXXXXX")" || {
		log_error "Could not create a temporary Dockerfile in ${DOCKLET_SYSTEM_DIR}."
		return 1
	}
	cat > "${dockerfile}"

	# An empty Dockerfile builds nothing useful and the failure is obscure, so catch it
	# here rather than letting the builder report it.
	if [ ! -s "${dockerfile}" ]; then
		log_error "image_build: the Dockerfile on stdin was empty."
		rm -f "${dockerfile}"
		return 1
	fi

	build_status=0
	container build -t "${tag}" "$@" -f "${dockerfile}" "$(container_build_context)" || build_status=$?
	rm -f "${dockerfile}"
	[ "${build_status}" -eq 0 ] || return "${build_status}"

	# A zero exit should mean the tag now resolves; if it doesn't, something is wrong
	# that a later "image not found" would only obscure.
	if ! image_exists "${tag}"; then
		log_error "container build reported success but ${tag} is not present locally."
		return 1
	fi

	date +%s > "$(image_stamp_path "${tag}" built)"
}

# Removes a docklet-built image so the next run rebuilds it from scratch — the shared
# implementation of the wrappers' `update` command. The optional second argument names
# what the rebuild will pick up (e.g. "the latest yt-dlp") and only shapes the message.
# Returns 0 when the image is gone, including when it was never there, and 1 when it
# exists but could not be removed — almost always another container still holding it.
# The caller decides what to do with that; this never exits on its own.
image_update() {
	local image what tool
	if [ -z "$1" ]; then
		log_error "image_update: no image given."
		exit 1
	fi
	image="$1"
	what="${2:-a fresh build}"
	tool="$(basename "$0")"

	if ! image_exists "${image}"; then
		log_info "No local image found; nothing to remove. A fresh image will be built or pulled on the next run."
		return 0
	fi

	log_info "Removing the local image so the next run replaces it with ${what}..."
	if ! image_remove "${image}"; then
		log_warn "Could not remove the image — it may still be in use by a running container. Close all ${tool} sessions, then run '${tool} update' again."
		return 1
	fi

	# The build stamp describes an image that no longer exists.
	rm -f "$(image_stamp_path "${image}" built)"
	log_info "Image removed. The updated image will be built or pulled on the next run."
	return 0
}

# Decides whether an image has to be (re)built, under one of three policies:
#   image_needs_build <image> missing              build only when absent
#   image_needs_build <image> age  <seconds>       ...or when older than <seconds>
#   image_needs_build <image> base <base-image>    ...or when the base digest moved
# Every policy implies "missing" — an absent image always needs building.
# Returns 0 when a build is needed, non-zero otherwise, and reports through globals:
#   - BUILD_REASON: "missing", "age", "base", or "none".
#   - BASE_CHECK:   base policy only — what the Docker Hub check did: "skipped" (still
#                   within STALENESS_PERIOD), "unchanged", "changed" or "unreachable".
#                   Empty under the other policies.
# Unlike registry_digest_changed this one logs, because every caller wants the same
# wording, and under the base policy it also drops the stale local base image when the
# digest moved, so the rebuild pulls the new one. Misuse (no image, unknown policy, a
# non-numeric period) exits rather than returning, so a caller bug can never be read as
# a quiet "no build needed".
image_needs_build() {
	local image policy policy_arg stored_digest digest_file
	image="$1"
	policy="$2"
	policy_arg="$3"
	BUILD_REASON="none"
	BASE_CHECK=""
	FETCHED_DIGEST=""

	if [ -z "${image}" ] || [ -z "${policy}" ]; then
		log_error "image_needs_build: usage: image_needs_build <image> missing|age <seconds>|base <base-image>"
		exit 1
	fi

	if ! image_exists "${image}"; then
		BUILD_REASON="missing"
		return 0
	fi

	case "${policy}" in
		missing)
			return 1
			;;

		age)
			case "${policy_arg}" in
				"" | *[!0-9]*)
					log_error "image_needs_build: the age policy needs a period in seconds, got '${policy_arg}'."
					exit 1
					;;
			esac
			image_stamp_stale "${image}" built "${policy_arg}" || return 1
			BUILD_REASON="age"
			return 0
			;;

		base)
			if [ -z "${policy_arg}" ]; then
				log_error "image_needs_build: the base policy needs a base image."
				exit 1
			fi

			# Ask Docker Hub at most once per STALENESS_PERIOD.
			image_stamp_stale "${image}" checked "${STALENESS_PERIOD}" || {
				BASE_CHECK="skipped"
				return 1
			}

			stored_digest=""
			digest_file="$(image_stamp_path "${image}" base-digest)"
			[ -f "${digest_file}" ] && stored_digest="$(cat "${digest_file}")"

			log_info "Checking Docker Hub for ${policy_arg} updates..."
			registry_digest_changed "${policy_arg}" "${stored_digest}" || true
			date +%s > "$(image_stamp_path "${image}" checked)"

			# A failed fetch is not a change — leave the image alone and try again next
			# time. The check timestamp is still written, so an outage can't turn every
			# run into a Docker Hub call.
			if [ -z "${FETCHED_DIGEST}" ]; then
				BASE_CHECK="unreachable"
				log_warn "Could not reach Docker Hub — skipping the ${policy_arg} check."
				return 1
			fi

			if [ "${DIGEST_CHANGED}" != "true" ]; then
				BASE_CHECK="unchanged"
				log_info "${policy_arg} is up to date."
				return 1
			fi

			BASE_CHECK="changed"
			BUILD_REASON="base"
			log_info "A new ${policy_arg} was published, refreshing the image..."
			# Drop the stale local base so the build pulls the fresh one.
			image_remove "${policy_arg}" || log_warn "Could not remove the local ${policy_arg}; the refresh may reuse it."
			return 0
			;;

		*)
			log_error "image_needs_build: unknown policy '${policy}' (expected missing, age or base)."
			exit 1
			;;
	esac
}

# Records which base digest an image was just built against, so the next base check of
# image_needs_build has a baseline. Call it after a successful build under the "base"
# policy. It reuses the digest image_needs_build already fetched when there is one, and
# fetches it otherwise — the first-build case, where the image was simply missing and no
# Hub check ran. A failed fetch records nothing, so the next run just checks again.
image_record_base() {
	if [ -z "$1" ] || [ -z "$2" ]; then
		log_error "image_record_base: usage: image_record_base <image> <base-image>"
		exit 1
	fi

	if [ -z "${FETCHED_DIGEST}" ]; then
		registry_digest_changed "$2" "" || true
	fi
	[ -n "${FETCHED_DIGEST}" ] || return 0

	printf '%s' "${FETCHED_DIGEST}" > "$(image_stamp_path "$1" base-digest)"
	date +%s > "$(image_stamp_path "$1" checked)"
}
