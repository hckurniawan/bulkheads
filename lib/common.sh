# docklet's shared library — the single entry point every wrapper sources:
#
#   DOCKLET_HOME="$(docklet home)" || { echo "docklet not found on PATH..." >&2; exit 1; }
#   . "${DOCKLET_HOME}/lib/common.sh"
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
# Each part guards against being sourced twice and pulls in its own dependencies, so a
# single layer can also be sourced on its own for testing.
#
# Source this from a wrapper (see bin/claude-code-cli); do not execute it directly.
# Containers are run with Apple's `container` CLI (Apple silicon, macOS 26+).

# $0 is the wrapper, not this file, so BASH_SOURCE is the only reliable handle to our
# own directory. `cd -P`/`dirname` rather than `readlink -f`, which is GNU-only —
# bin/docklet resolves its own path the same way.
DOCKLET_LIB_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for _docklet_part in core args engine registry image; do
	if [ ! -r "${DOCKLET_LIB_DIR}/${_docklet_part}.sh" ]; then
		# core.sh may not have loaded yet, so log_error() isn't available.
		echo "docklet: missing library part ${DOCKLET_LIB_DIR}/${_docklet_part}.sh" >&2
		exit 1
	fi
	. "${DOCKLET_LIB_DIR}/${_docklet_part}.sh"
done
unset _docklet_part
