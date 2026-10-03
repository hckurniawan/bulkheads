# bulkhead — paths, logging and per-wrapper data directories.
#
# The bottom layer: this file calls neither `container` nor curl, and nothing above it
# may reach back into it for anything else. Everything here is inert to source.

# Part of bulkhead's shared library; loaded by lib/common.sh. Source-only — this file
# defines functions and variables and executes nothing.
if [ -n "${_BULKHEAD_CORE_SH:-}" ]; then return 0; fi
_BULKHEAD_CORE_SH=1

# Root under which every wrapper persists its isolated state.
BULKHEAD_DATA_DIR="${HOME}/bulkhead-data"
BULKHEAD_SYSTEM_DIR="${BULKHEAD_DATA_DIR}/.bulkhead"

# bulkhead's version (semver), matched by a `vX.Y.Z` git tag. Sources declare the
# minimum version they rely on; MAJOR changes only when the public lib API, the preamble,
# the data layout or the bulkhead-source format breaks (see AGENTS.md).
BULKHEAD_VERSION="2.0.0"

# Where `bulkhead source add` clones child repositories, one folder per source name.
# It's inside BULKHEAD_SYSTEM_DIR, so everything bulkhead owns sits under one folder, and
# no wrapper's data folder can clash with it (data_dir rejects names starting with a dot).
BULKHEAD_SOURCES_DIR="${BULKHEAD_SYSTEM_DIR}/sources"

# How often (in seconds) wrappers check for a stale base/official image on Docker Hub
# (the registry `container` pulls from — not the Docker engine, which bulkhead no longer
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
# dot or contains a slash is rejected, so the path can never leave BULKHEAD_DATA_DIR
# or land on .bulkhead.
data_dir() {
	local name
	name="${1-$(basename "$0")}"

	case "${name}" in
		"" | .* | */*)
			log_error "data_dir: '${name}' is not a valid data directory name." >&2
			return 1
			;;
	esac

	printf '%s/%s' "${BULKHEAD_DATA_DIR}" "${name}"
}

# Validates a semver version and prints it as "MAJOR MINOR PATCH", padding a missing
# minor or patch with 0, so "2" prints "2 0 0". Accepts X, X.Y or X.Y.Z; with "full" as
# the second argument, only X.Y.Z. Each part is 0 or a number without leading zeros, as
# semver requires. Pre-releases (-rc.1), build metadata (+b), ranges and operators are
# all rejected. Returns 1, without logging, when the version is invalid; callers word
# the error.
# Internal: not part of the public API, so sources must not call it (see AGENTS.md).
_semver_parse() {
	local version major minor patch
	version="$1"

	# Only digits and dots, which also rules out a newline sneaking past grep's
	# line-by-line match below.
	case "${version}" in
		"" | *[!0-9.]*) return 1 ;;
	esac
	if [ "$2" = "full" ]; then
		printf '%s' "${version}" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || return 1
	else
		printf '%s' "${version}" | grep -Eq '^(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*)){0,2}$' || return 1
	fi

	IFS=. read -r major minor patch <<< "${version}"
	printf '%s %s %s' "${major}" "${minor:-0}" "${patch:-0}"
}

# Compares two numbers given as strings without leading zeros, printing lt, eq or gt.
# Comparing by length first, then as strings, is exact for any size and needs no shell
# arithmetic, so a huge version number can't overflow.
# Internal: not part of the public API, so sources must not call it (see AGENTS.md).
_semver_num_cmp() {
	if [ "${#1}" -lt "${#2}" ]; then
		echo lt
	elif [ "${#1}" -gt "${#2}" ]; then
		echo gt
	elif [[ "$1" < "$2" ]]; then
		echo lt
	elif [[ "$1" > "$2" ]]; then
		echo gt
	else
		echo eq
	fi
}

# Compares two versions already parsed by _semver_parse ("MAJOR MINOR PATCH"), printing
# lt, eq or gt for the first against the second.
# Internal: not part of the public API, so sources must not call it (see AGENTS.md).
_semver_compare() {
	local a1 a2 a3 b1 b2 b3 result
	read -r a1 a2 a3 <<< "$1"
	read -r b1 b2 b3 <<< "$2"

	result="$(_semver_num_cmp "${a1}" "${b1}")"
	[ "${result}" = "eq" ] || { echo "${result}"; return 0; }
	result="$(_semver_num_cmp "${a2}" "${b2}")"
	[ "${result}" = "eq" ] || { echo "${result}"; return 0; }
	_semver_num_cmp "${a3}" "${b3}"
}

# Reports success when the installed BULKHEAD_VERSION satisfies a source's requirement,
# given as X, X.Y or X.Y.Z (missing parts count as 0): the same major, and an installed
# version at least the required one. So requires=2 accepts any 2.x.y, and 2.1.3 accepts
# 2.1.3 up to, not including, 3.0.0. Major 0 is never valid: bulkhead has no 0.x
# releases. An invalid requirement is a caller bug, and an invalid BULKHEAD_VERSION a
# bulkhead bug; both exit, so neither can ever be read as "compatible".
# Internal: not part of the public API, so sources must not call it (see AGENTS.md).
_bulkhead_version_satisfies() {
	local required installed
	if ! required="$(_semver_parse "$1")" || [ "${required%% *}" = "0" ]; then
		log_error "_bulkhead_version_satisfies: usage: _bulkhead_version_satisfies <major>[.<minor>[.<patch>]] (got '$1')" >&2
		exit 1
	fi
	if ! installed="$(_semver_parse "${BULKHEAD_VERSION}" full)"; then
		log_error "BULKHEAD_VERSION '${BULKHEAD_VERSION}' isn't a plain X.Y.Z version; this is a bug in bulkhead." >&2
		exit 1
	fi

	[ "$(_semver_num_cmp "${installed%% *}" "${required%% *}")" = "eq" ] \
		&& [ "$(_semver_compare "${installed}" "${required}")" != "lt" ]
}

# Prints the `requires` value from a source's bulkhead-source manifest, as written there.
# The manifest comes from another repository, so it is parsed as key=value lines and
# never sourced or eval'd; comments, blank lines and unknown keys are ignored (see
# examples/source/bulkhead-source). Whitespace around the value, including the CR of a
# CRLF line ending, is trimmed. Returns 1 when the manifest is missing or unreadable, or
# its requires value is absent or isn't X, X.Y or X.Y.Z with a major of at least 1.
# Internal: not part of the public API, so sources must not call it (see AGENTS.md).
_bulkhead_source_requires() {
	local manifest key value required parsed
	manifest="$1/bulkhead-source"
	required=""

	[ -f "${manifest}" ] && [ -r "${manifest}" ] || return 1

	while IFS='=' read -r key value || [ -n "${key}" ]; do
		if [ "${key}" = "requires" ]; then
			required="${value}"
		fi
	done < "${manifest}"

	required="${required#"${required%%[![:space:]]*}"}"
	required="${required%"${required##*[![:space:]]}"}"

	parsed="$(_semver_parse "${required}")" || return 1
	[ "${parsed%% *}" != "0" ] || return 1
	printf '%s' "${required}"
}
