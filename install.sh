#!/bin/bash
# Bootstrap installer for docklet. Clones the repository into ~/.local/share and
# symlinks the docklet manager onto PATH. This script is standalone — it runs
# before docklet exists, so it cannot source lib/common.sh and defines its own
# minimal log helpers.
set -e

REPO_URL="https://github.com/hckurniawan/docklets.git"
BASE_INSTALL_DIR="${HOME}/.local"
DEFAULT_SHARE_DIR="${BASE_INSTALL_DIR}/share/docklets"
BIN_DIR="${BASE_INSTALL_DIR}/bin"

# Oldest Apple `container` CLI docklet supports, as major.minor.
CONTAINER_MIN_VERSION="1.5"

# Populated by resolve_share_dir: where the clone lives and whether install.sh is
# being run from inside an existing checkout (in which case nothing is cloned).
SHARE_DIR="${DEFAULT_SHARE_DIR}"
IN_REPO="false"

# Coloured log helpers (mirrors lib/common.sh, kept local so install.sh stays
# self-contained and runnable straight from a curl|bash before the clone exists).
log_info()  { printf '\033[38;5;153m[INFO]\033[0m %s\n'  "$*"; }
log_warn()  { printf '\033[38;5;229m[WARN]\033[0m %s\n'  "$*"; }
log_error() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*"; }

# Normalises a git remote URL to "host/path" (no scheme, no user, no .git suffix,
# lowercased) so the SSH (git@github.com:owner/repo.git) and HTTPS
# (https://github.com/owner/repo.git) forms of the same repo compare equal.
normalize_git_url() {
	url="${1%.git}"
	case "${url}" in
		*://*) url="${url#*://}"; url="${url#*@}" ;;        # [scheme]://[user@]host/path
		*@*:*) url="${url#*@}"; url="${url%%:*}/${url#*:}" ;; # user@host:path (scp-style)
	esac
	printf '%s' "${url}" | tr 'A-Z' 'a-z'
}

# Reports success when two git remote URLs refer to the same repository, comparing
# their normalised forms so SSH and HTTPS spellings are treated as equivalent.
same_repo() {
	[ "$(normalize_git_url "$1")" = "$(normalize_git_url "$2")" ]
}

# Exits with an error unless the named command is available on PATH.
require_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		log_error "$1 is required to install and run docklet, but was not found on PATH."
		exit 1
	fi
	log_info "Found required command: $1."
}

# Exits with an error unless Apple's `container` CLI is on PATH, pointing at the
# installer rather than the generic require_cmd message. Does not check or start the
# system service — the wrappers do that themselves at run time.
require_container_cli() {
	if ! command -v container >/dev/null 2>&1; then
		log_error "Apple's \`container\` CLI is required to run docklet, but was not found on PATH."
		log_error "Install it from https://github.com/apple/container/releases (Apple silicon, macOS 26+)."
		exit 1
	fi
	log_info "Found required command: container."
}

# Exits with an error unless `container --version` reports CONTAINER_MIN_VERSION or
# newer. The first X.Y or X.Y.Z in the output is taken as the version, so extra words
# around it don't matter; output with no version in it is an error rather than a guess.
# Only major and minor are compared, so any patch release of the minimum qualifies.
require_container_version() {
	local output version major minor min_major min_minor
	if ! output="$(container --version 2>&1)"; then
		log_error "Could not read the container CLI version: \`container --version\` failed."
		log_error "Output: ${output:-<none>}"
		exit 1
	fi

	version="$(printf '%s\n' "${output}" | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1 || true)"
	if [ -z "${version}" ]; then
		log_error "Could not find a version number in \`container --version\` output: ${output:-<none>}"
		exit 1
	fi

	major="${version%%.*}"
	minor="${version#*.}"
	minor="${minor%%.*}"
	min_major="${CONTAINER_MIN_VERSION%%.*}"
	min_minor="${CONTAINER_MIN_VERSION#*.}"

	if [ "${major}" -lt "${min_major}" ] \
		|| { [ "${major}" -eq "${min_major}" ] && [ "${minor}" -lt "${min_minor}" ]; }; then
		log_error "docklet needs Apple's \`container\` CLI ${CONTAINER_MIN_VERSION} or newer, but found ${version}."
		log_error "Update it from https://github.com/apple/container/releases"
		exit 1
	fi
	log_info "Found container ${version} (${CONTAINER_MIN_VERSION} or newer required)."
}

# Verifies all host prerequisites (Bash, Git, container) are present, and that
# container is new enough.
require_prerequisites() {
	require_cmd bash
	require_cmd git
	require_container_cli
	require_container_version
}

# Creates the ~/.local directory tree (share and bin) when missing.
ensure_dirs() {
	mkdir -p "${BASE_INSTALL_DIR}" "${BASE_INSTALL_DIR}/share" "${BIN_DIR}"
}

# Decides where the docklet clone lives. If install.sh is being run from within an
# existing docklet checkout (it sits at the repo root next to bin/docklet), that
# checkout is used in place and nothing is cloned. Otherwise the default
# ~/.local/share/docklets location is used and clone_repo populates it. $0 only
# resolves to a real file when run as a script (not piped via curl|sh), so a piped
# run always falls through to the clone path.
resolve_share_dir() {
	log_info "Resolving docklet location..."
	src="$0"
	if [ ! -f "${src}" ]; then
		log_info "Not running from a script file (piped install); will clone into ${DEFAULT_SHARE_DIR}."
		return 0
	fi
	# Resolve symlinks by hand (readlink -f is GNU-only) to find the real file.
	while [ -h "${src}" ]; do
		dir="$(cd -P "$(dirname "${src}")" && pwd)"
		src="$(readlink "${src}")"
		case "${src}" in /*) ;; *) src="${dir}/${src}" ;; esac
	done
	script_dir="$(cd -P "$(dirname "${src}")" && pwd)"
	log_info "Running from ${script_dir}."

	# Use the checkout in place only if it really is a docklet clone of REPO_URL:
	# it must sit at a repo root (bin/docklet + .git) and its origin must match, so
	# install.sh run from an unrelated or forked repo still installs the right thing.
	if [ ! -f "${script_dir}/bin/docklet" ] || [ ! -d "${script_dir}/.git" ]; then
		log_info "Not a docklet checkout (no bin/docklet or .git); will clone into ${DEFAULT_SHARE_DIR}."
		return 0
	fi
	remote="$(git -C "${script_dir}" remote get-url origin 2>/dev/null || true)"
	if same_repo "${remote}" "${REPO_URL}"; then
		log_info "Verified docklet checkout (origin ${remote}); using it in place."
		SHARE_DIR="${script_dir}"
		IN_REPO="true"
	else
		log_error "Running from a git checkout at ${script_dir} whose origin is '${remote:-<none>}', not ${REPO_URL}."
		log_error "Refusing to install from an unexpected repository. Run install.sh from a docklet clone, or pipe it from ${REPO_URL}."
		exit 1
	fi
}

# Clones the docklet repository into the share dir. If a clone already exists,
# pulls the latest scripts instead of re-cloning. Errors if the path exists but
# is not a docklet clone, so an unrelated directory is never clobbered.
clone_repo() {
	if [ "${IN_REPO}" = "true" ]; then
		log_info "Running from an existing checkout at ${SHARE_DIR}; using it in place."
		return 0
	fi
	if [ -d "${SHARE_DIR}/.git" ]; then
		remote="$(git -C "${SHARE_DIR}" remote get-url origin 2>/dev/null || true)"
		if ! same_repo "${remote}" "${REPO_URL}"; then
			log_warn "${SHARE_DIR} is a git clone of '${remote:-<none>}', not ${REPO_URL}."
			log_warn "Leaving it untouched; remove it and re-run to install from ${REPO_URL}."
			return 0
		fi
		log_info "docklet is already cloned at ${SHARE_DIR}; pulling latest scripts..."
		git -C "${SHARE_DIR}" pull --ff-only
		return 0
	fi
	if [ -e "${SHARE_DIR}" ]; then
		log_error "${SHARE_DIR} exists but is not a git clone; remove it and re-run."
		exit 1
	fi
	log_info "Cloning docklet into ${SHARE_DIR}..."
	git clone "${REPO_URL}" "${SHARE_DIR}"
}

# Symlinks the docklet manager from the clone into ~/.local/bin.
link_docklet() {
	src="${SHARE_DIR}/bin/docklet"
	dst="${BIN_DIR}/docklet"
	if [ ! -f "${src}" ]; then
		log_error "Expected manager script not found at ${src}."
		exit 1
	fi
	ln -sf "${src}" "${dst}"
	log_info "Linked: ${dst} -> ${src}"
}

# Warns the user if ~/.local/bin is not on PATH, with a hint on how to add it.
check_path() {
	case ":${PATH}:" in
		*":${BIN_DIR}:"*)
			log_info "${BIN_DIR} is on your PATH."
			;;
		*)
			log_warn "${BIN_DIR} is not on your PATH."
			log_warn "Add it by appending this line to your shell profile (e.g. ~/.bashrc or ~/.zshrc):"
			log_warn "    export PATH=\"${BIN_DIR}:\${PATH}\""
			;;
	esac
}

main() {
	require_prerequisites
	resolve_share_dir
	ensure_dirs
	clone_repo
	link_docklet
	check_path
	log_info "docklet installed. Run 'docklet help' to get started."
}

main "$@"
