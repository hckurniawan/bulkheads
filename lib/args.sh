# docklet — wrapper argument parsing: the `update`-style command and the `--` separator.
#
# Pure string handling on top of core.sh. Every wrapper that takes a command of its own
# parses it the same way through args_parse, so `--` behaves identically everywhere.

# Part of docklet's shared library; loaded by lib/common.sh. Source-only — this file
# defines functions and variables and executes nothing.
if [ -n "${_DOCKLET_ARGS_SH:-}" ]; then return 0; fi
_DOCKLET_ARGS_SH=1

# Resolve this part's own directory so it can pull in what it depends on, making it
# sourceable on its own (handy for testing a layer in isolation). $0 is the wrapper,
# not this file, so BASH_SOURCE is the only reliable handle.
: "${DOCKLET_LIB_DIR:=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
. "${DOCKLET_LIB_DIR}/core.sh"

# Splits a wrapper's arguments into its own command and the arguments to forward into
# the container:
#   args_parse update "$@"
# The first parameter is the one wrapper-level command this script recognises; the rest
# are the wrapper's own "$@". Reports through two globals, so nothing is consumed twice:
#   - ARGS_COMMAND: the command if it was given, empty otherwise.
#   - FORWARD_ARGS: an array of everything else, in order, for the container.
# The rules are identical for every wrapper:
#   * The command counts only as a bare word BEFORE the first `--`.
#   * `--` ends wrapper-level parsing and is consumed. Everything after it is forwarded
#     verbatim, so `yt-dlp -- update` passes the word `update` to yt-dlp itself.
#   * Anything unrecognised is forwarded untouched, so tool flags pass straight through.
# The command is matched by exact string comparison, never as a shell pattern, so an
# argument like `*` can never be mistaken for it. Repeating the command is a usage error
# rather than a silent no-op. Callers act on ARGS_COMMAND and decide their own exit
# status; args_parse never runs the command itself.
args_parse() {
	local command arg scanning
	if [ -z "$1" ]; then
		log_error "args_parse: no command name given."
		exit 1
	fi
	command="$1"
	shift

	ARGS_COMMAND=""
	FORWARD_ARGS=()
	scanning=true

	for arg in "$@"; do
		if [ "${scanning}" = true ]; then
			if [ "${arg}" = "--" ]; then
				scanning=false
				continue
			fi
			if [ "${arg}" = "${command}" ]; then
				if [ -n "${ARGS_COMMAND}" ]; then
					log_error "'${command}' was given twice; pass it once, or after \`--\` to send it to the tool."
					exit 1
				fi
				ARGS_COMMAND="${arg}"
				continue
			fi
		fi
		FORWARD_ARGS+=("${arg}")
	done
}
