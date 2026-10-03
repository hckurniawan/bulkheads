# bulkhead tests — assertions, a throwaway HOME per case, and a fixture source.
#
# Sourced by each tests/*.test.sh. Nothing here calls `container`: the tests cover the
# manager's linking and the lib's greppable rules, never a wrapper's run.

TESTS_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -P "${TESTS_DIR}/.." && pwd)"

# Points HOME at a fresh temporary directory, so ~/bulkhead-data, the sources dir and
# the bin dir all live inside it, and puts a bulkhead link first on PATH. The EXIT trap
# removes the directory; each case runs in its own subshell, so each gets its own.
sandbox_new() {
	# Physical path, as the manager prints it: on macOS TMPDIR is under /var, a symlink
	# to /private/var, and ends in a slash.
	SANDBOX="$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/bulkhead-test.XXXXXX")" && pwd)"
	trap 'rm -rf "${SANDBOX}"' EXIT
	export HOME="${SANDBOX}"
	BIN="${SANDBOX}/bin"
	mkdir -p "${BIN}"
	ln -s "${REPO_DIR}/bin/bulkhead" "${BIN}/bulkhead"
	export PATH="${BIN}:${PATH}"
	# Refuse to go on unless the sandbox is real and its bulkhead shadows any installed
	# one: otherwise a case would add and remove links in the user's real bin dir.
	[ -n "${SANDBOX}" ] && [ -d "${SANDBOX}" ] || { echo "sandbox_new: no temp dir" >&2; exit 1; }
	[ "$(command -v bulkhead)" = "${BIN}/bulkhead" ] || { echo "sandbox_new: bulkhead not shadowed" >&2; exit 1; }
	# Keep git off the user's system and XDG config, so fixture commits run no real
	# hooks and never try to sign.
	export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null XDG_CONFIG_HOME="${SANDBOX}/.config"
	# Taken from lib/core.sh under the sandbox HOME, so tests follow it if it moves.
	SOURCES_DIR="$(. "${REPO_DIR}/lib/core.sh" && printf '%s' "${BULKHEAD_SOURCES_DIR}")"
}

# The major.minor of this checkout's BULKHEAD_VERSION.
current_requires() {
	sed -n 's/^BULKHEAD_VERSION="\([0-9]*\.[0-9]*\)\..*"$/\1/p' "${REPO_DIR}/lib/core.sh"
}

# Builds a git repository of stub wrappers and registers it as source <name>. Each
# stub is only a shebang and its `# bulkhead-needs:` header; none is ever run.
#   a -> b -> c        a chain
#   x <-> y            a cycle
#   bad -> nosuch      a need that doesn't exist
#   uses-core -> core/gpg
fixture_source() {
	local repo
	repo="${SANDBOX}/fixture-repo"
	mkdir -p "${repo}/bin"
	printf 'requires=%s\n' "$(current_requires)" > "${repo}/bulkhead-source"
	_stub "${repo}" a "b"
	_stub "${repo}" b "c"
	_stub "${repo}" c ""
	_stub "${repo}" x "y"
	_stub "${repo}" y "x"
	_stub "${repo}" bad "nosuch"
	_stub "${repo}" uses-core "core/gpg"
	git -C "${repo}" init -q
	git -C "${repo}" add -A
	git -C "${repo}" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
	bulkhead source add "$1" "${repo}" >/dev/null
}

# Writes one stub wrapper; an empty needs list writes no header line.
_stub() {
	{
		printf '#!/bin/bash\n# Fixture wrapper %s.\n' "$2"
		[ -z "$3" ] || printf '# bulkhead-needs: %s\n' "$3"
		printf 'set -e\necho %s\n' "$2"
	} > "$1/bin/$2"
	chmod +x "$1/bin/$2"
}

# Fails the current case with a message.
fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# Asserts that bin/<name> is a symlink to <target>.
assert_link() {
	[ -h "${BIN}/$1" ] || fail "${BIN}/$1 is not a link"
	[ "$(readlink "${BIN}/$1")" = "$2" ] || fail "${BIN}/$1 -> $(readlink "${BIN}/$1"), expected $2"
}

# Asserts that nothing exists at bin/<name>.
assert_no_link() {
	[ ! -e "${BIN}/$1" ] && [ ! -h "${BIN}/$1" ] || fail "${BIN}/$1 exists"
}

# Runs a command and asserts its exit status. Its output is kept in OUT.
assert_status() {
	local expected status
	expected="$1"
	shift
	status=0
	OUT="$("$@" 2>&1)" || status=$?
	[ "${status}" -eq "${expected}" ] || fail "'$*' exited ${status}, expected ${expected}; output:
${OUT}"
}

# Asserts that OUT (from the last assert_status or capture) contains <text>.
assert_out_contains() {
	case "${OUT}" in
		*"$1"*) ;;
		*) fail "output doesn't contain '$1'; output:
${OUT}" ;;
	esac
}

# Runs every test_* function defined by the calling file, each in its own subshell with
# a fresh sandbox, and prints PASS, FAIL or SKIP per case. A case skips by exiting 77.
# Returns 1 when any case failed.
run_tests() {
	local fn log status failed
	failed=0
	log="$(mktemp "${TMPDIR:-/tmp}/bulkhead-test-log.XXXXXX")"

	for fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
		# Not `|| status=$?`: that would switch off set -e inside the subshell.
		set +e
		# set -e first, so a failing sandbox_new stops the case before it runs.
		( set -e; sandbox_new; "${fn}" ) > "${log}" 2>&1
		status=$?
		set -e
		case "${status}" in
			0) echo "PASS ${fn}" ;;
			77) echo "SKIP ${fn}: $(tail -1 "${log}")" ;;
			*)
				echo "FAIL ${fn}"
				sed 's/^/    /' "${log}"
				failed=1
				;;
		esac
	done

	rm -f "${log}"
	return "${failed}"
}

# Exits the current case as skipped, with a reason.
skip() {
	echo "$*"
	exit 77
}
