# docklet — paths, logging and per-wrapper data directories.
#
# The bottom layer: this file calls neither `container` nor curl, and nothing above it
# may reach back into it for anything else. Everything here is inert to source.

# Part of docklet's shared library; loaded by lib/common.sh. Source-only — this file
# defines functions and variables and executes nothing.
if [ -n "${_DOCKLET_CORE_SH:-}" ]; then return 0; fi
_DOCKLET_CORE_SH=1

# Root under which every wrapper persists its isolated state.
PERSISTENT_DATA_DIR="${HOME}/docklet-data"
DOCKLET_SYSTEM_DIR="${PERSISTENT_DATA_DIR}/.docklet"

# How often (in seconds) wrappers check for a stale base/official image on Docker Hub
# (the registry `container` pulls from — not the Docker engine, which docklet no longer
# uses). Defaults to once a day; bump it to check more or less frequently.
STALENESS_PERIOD="$(( 24 * 60 * 60 ))"

# Coloured log helpers.
log_info()  { printf '\033[38;5;153m[INFO]\033[0m %s\n'  "$*"; }
log_warn()  { printf '\033[38;5;229m[WARN]\033[0m %s\n'  "$*"; }
log_error() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*"; }

# Prints this wrapper's isolated data directory, derived from the *invoked* name
# (basename "$0") — so symlinking a wrapper under a different name yields a fully
# separate config. Must stay based on the invoked name, never the resolved path.
# Given a name, prints that name's directory instead, for a wrapper that uses another
# wrapper's data (git-secret uses a gpg keyring). A name that is empty, starts with a
# dot or contains a slash is rejected, so the path can never leave PERSISTENT_DATA_DIR
# or land on .docklet.
data_dir() {
	local name
	name="${1-$(basename "$0")}"

	case "${name}" in
		"" | .* | */*)
			log_error "data_dir: '${name}' is not a valid data directory name." >&2
			return 1
			;;
	esac

	printf '%s/%s' "${PERSISTENT_DATA_DIR}" "${name}"
}
