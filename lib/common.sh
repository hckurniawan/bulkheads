# bulkhead's shared library — the single entry point every wrapper sources:
#
#   BULKHEAD_HOME="$(bulkhead home)" || { echo "bulkhead not found on PATH..." >&2; exit 1; }
#   . "${BULKHEAD_HOME}/lib/common.sh"
#
# This file only loads the parts, in dependency order, so wrappers never need to know
# the layout. The split is by layer, and the layering is deliberately greppable:
#
#   core.sh      paths, logging, data dirs   calls neither `container` nor curl
#   args.sh      wrapper argument parsing    pure string handling
#   engine.sh    the `container` CLI         no curl
#   registry.sh  Docker Hub over HTTPS       no `container`
#   image.sh     the image lifecycle         built on all three
#
# A part whose name starts with `_` (today only _deps.sh) is manager-only: bin/bulkhead
# sources it, and this loader never does, so wrappers never see its functions.
#
# Each part guards against being sourced twice and pulls in its own dependencies, so a
# single layer can also be sourced on its own for testing.
#
# Source this from a wrapper (see bin/claude); do not execute it directly.
# Containers are run with Apple's `container` CLI (Apple silicon, macOS 26+).

# $0 is the wrapper, not this file, so BASH_SOURCE is the only reliable handle to our
# own directory. `cd -P`/`dirname` rather than `readlink -f`, which is GNU-only —
# bin/bulkhead resolves its own path the same way.
BULKHEAD_LIB_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for _bulkhead_part in core args engine registry image; do
	if [ ! -r "${BULKHEAD_LIB_DIR}/${_bulkhead_part}.sh" ]; then
		# core.sh may not have loaded yet, so log_error() isn't available.
		echo "bulkhead: missing library part ${BULKHEAD_LIB_DIR}/${_bulkhead_part}.sh" >&2
		exit 1
	fi
	. "${BULKHEAD_LIB_DIR}/${_bulkhead_part}.sh"
done
unset _bulkhead_part

# A wrapper from a source (a child repository under BULKHEAD_SOURCES_DIR) relies on this
# lib's API, so check the source's declared requirement before the wrapper runs. This
# is the loader acting, not a part: the parts stay source-only. Follow $0's symlink
# chain by hand (no readlink -f) to find which repository the wrapper really lives in;
# core wrappers resolve into the core bin/ and are never checked.
_bulkhead_src="$0"
while [ -h "${_bulkhead_src}" ]; do
	_bulkhead_dir="$(cd -P "$(dirname "${_bulkhead_src}")" && pwd)"
	_bulkhead_src="$(readlink "${_bulkhead_src}")"
	case "${_bulkhead_src}" in /*) ;; *) _bulkhead_src="${_bulkhead_dir}/${_bulkhead_src}" ;; esac
done
_bulkhead_dir="$(cd -P "$(dirname "${_bulkhead_src}")" 2>/dev/null && pwd || true)"
# Compare physical paths on both sides, in case part of HOME is a symlink.
_bulkhead_sources="$(cd -P "${BULKHEAD_SOURCES_DIR}" 2>/dev/null && pwd || true)"
_bulkhead_source=""
case "${_bulkhead_dir}" in
	"${_bulkhead_sources:-/nonexistent}"/*/bin)
		_bulkhead_source="${_bulkhead_dir#"${_bulkhead_sources}/"}"
		_bulkhead_source="${_bulkhead_source%/bin}"
		# A source's bin/ sits directly in its clone; anything deeper isn't a source wrapper.
		case "${_bulkhead_source}" in */*) _bulkhead_source="" ;; esac
		;;
esac
if [ -n "${_bulkhead_source}" ]; then
	if ! _bulkhead_required="$(_bulkhead_source_requires "${_bulkhead_sources}/${_bulkhead_source}")"; then
		log_error "Source '${_bulkhead_source}' has no valid bulkhead-source manifest (requires=<major>[.<minor>[.<patch>]])." >&2
		exit 1
	fi
	if ! _bulkhead_version_satisfies "${_bulkhead_required}"; then
		log_error "Source '${_bulkhead_source}' needs bulkhead ${_bulkhead_required}, but bulkhead ${BULKHEAD_VERSION} is installed." >&2
		if [ "${BULKHEAD_VERSION%%.*}" -gt "${_bulkhead_required%%.*}" ]; then
			log_error "Update the source for bulkhead ${BULKHEAD_VERSION%%.*}.x, then run 'bulkhead update'." >&2
		else
			log_error "Run 'bulkhead update' to get a newer bulkhead." >&2
		fi
		exit 1
	fi
fi
unset _bulkhead_src _bulkhead_dir _bulkhead_sources _bulkhead_source _bulkhead_required
