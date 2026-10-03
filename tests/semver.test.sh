#!/bin/bash
# Tests for the semver check on a source's `requires=`: the lib/core.sh helpers on their
# own, and `bulkhead source add` accepting or refusing a source because of it.
set -e

. "$(cd -P "$(dirname "$0")" && pwd)/lib.sh"

# Asserts that _semver_parse prints <expected> for <version> (optionally "full").
assert_parses() {
	local got
	got="$(_semver_parse "$1" $3)" || fail "'$1' was rejected"
	[ "${got}" = "$2" ] || fail "'$1' parsed as '${got}', expected '$2'"
}

# Asserts that _semver_parse rejects <version> (optionally "full").
assert_rejected() {
	! _semver_parse "$1" $2 >/dev/null || fail "'$1' was accepted"
}

# Writes a manifest with the given raw content into a fresh folder and prints the folder.
manifest_dir() {
	local dir
	dir="$(mktemp -d "${SANDBOX}/manifest.XXXXXX")"
	printf '%b' "$1" > "${dir}/bulkhead-source"
	printf '%s' "${dir}"
}

# Registers a one-wrapper source whose manifest says requires=<value>.
add_source_requiring() {
	local repo
	repo="${SANDBOX}/repo-$1"
	mkdir -p "${repo}/bin"
	printf 'requires=%s\n' "$2" > "${repo}/bulkhead-source"
	printf '#!/bin/bash\necho tool\n' > "${repo}/bin/tool-$1"
	chmod +x "${repo}/bin/tool-$1"
	git -C "${repo}" init -q
	git -C "${repo}" add -A
	git -C "${repo}" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
	bulkhead source add "$1" "${repo}"
}

# The installed version's parts, from this checkout's lib/core.sh.
installed_part() {
	( . "${REPO_DIR}/lib/core.sh" && printf '%s' "${BULKHEAD_VERSION}" ) | cut -d. -f"$1"
}

# --- _semver_parse ------------------------------------------------------------------

test_parse_accepts_one_two_or_three_parts() {
	. "${REPO_DIR}/lib/core.sh"
	assert_parses 2 "2 0 0"
	assert_parses 2.1 "2 1 0"
	assert_parses 2.1.3 "2 1 3"
	assert_parses 10.20.30 "10 20 30"
	assert_parses 2.0.0 "2 0 0"
}

test_parse_rejects_non_semver() {
	. "${REPO_DIR}/lib/core.sh"
	local v
	for v in 02 2.01 2.1.03 2.1.0-rc.1 2.1+b 2.1.0+build.5 1.2.3.4 '^2' '>=2' '~2.1' v2 \
		'' 2. .2 2..1 ' 2' 'x' '2 3'; do
		assert_rejected "${v}"
	done
	assert_rejected "$(printf '2\n3')"
}

test_parse_full_needs_three_parts() {
	. "${REPO_DIR}/lib/core.sh"
	assert_parses 2.0.0 "2 0 0" full
	assert_rejected 2 full
	assert_rejected 2.0 full
	assert_rejected 2.0.0-rc.1 full
}

# --- _semver_compare ----------------------------------------------------------------

test_compare_is_numeric_not_textual() {
	. "${REPO_DIR}/lib/core.sh"
	[ "$(_semver_compare "2 10 0" "2 9 0")" = gt ] || fail "2.10 should be after 2.9"
	[ "$(_semver_compare "2 9 0" "2 10 0")" = lt ] || fail "2.9 should be before 2.10"
	[ "$(_semver_compare "2 1 3" "2 1 3")" = eq ] || fail "2.1.3 should equal itself"
	[ "$(_semver_compare "2 1 0" "2 0 9")" = gt ] || fail "minor should outrank patch"
	[ "$(_semver_compare "2 99999999999999999999 0" "2 99999999999999999998 0")" = gt ] \
		|| fail "long numbers compared wrongly"
}

# --- _bulkhead_version_satisfies -----------------------------------------------------

test_satisfies_same_major_at_least_required() {
	. "${REPO_DIR}/lib/core.sh"
	BULKHEAD_VERSION="2.3.1"
	local r
	for r in 2 2.0 2.3 2.3.1 2.0.9; do
		_bulkhead_version_satisfies "${r}" || fail "2.3.1 should satisfy ${r}"
	done
	for r in 2.3.2 2.4 2.10 3 3.0.0 1 1.9; do
		! _bulkhead_version_satisfies "${r}" || fail "2.3.1 shouldn't satisfy ${r}"
	done
}

test_satisfies_exits_on_invalid_requirement() {
	local r
	for r in 0 0.1 2.1.0-rc.1 '>=2' ''; do
		assert_status 1 bash -c '. "$1/lib/core.sh"; BULKHEAD_VERSION=2.3.1; _bulkhead_version_satisfies "$2"; exit 0' _ "${REPO_DIR}" "${r}"
		assert_out_contains "usage"
	done
}

test_satisfies_exits_on_invalid_installed_version() {
	local v
	for v in 2.3 2.3.1-rc.1 v2.3.1 2.3.1+b ''; do
		assert_status 1 bash -c '. "$1/lib/core.sh"; BULKHEAD_VERSION="$2"; _bulkhead_version_satisfies 2; exit 0' _ "${REPO_DIR}" "${v}"
		assert_out_contains "isn't a plain X.Y.Z version"
	done
}

test_installed_version_is_plain_semver() {
	. "${REPO_DIR}/lib/core.sh"
	_semver_parse "${BULKHEAD_VERSION}" full >/dev/null || fail "BULKHEAD_VERSION '${BULKHEAD_VERSION}' isn't X.Y.Z"
}

# --- _bulkhead_source_requires -------------------------------------------------------

test_manifest_tolerates_crlf_and_spaces() {
	. "${REPO_DIR}/lib/core.sh"
	[ "$(_bulkhead_source_requires "$(manifest_dir 'requires=2\r\n')")" = "2" ] || fail "CRLF"
	[ "$(_bulkhead_source_requires "$(manifest_dir 'requires= 2.1 \n')")" = "2.1" ] || fail "spaces"
	[ "$(_bulkhead_source_requires "$(manifest_dir '# c\n\nother=x\nrequires=2.0.3')")" = "2.0.3" ] \
		|| fail "comments, unknown keys, no final newline"
}

test_manifest_rejects_invalid_requires() {
	. "${REPO_DIR}/lib/core.sh"
	local v
	for v in 2.1.0-rc.1 '>=2' 0.1 02 ''; do
		! _bulkhead_source_requires "$(manifest_dir "requires=${v}\n")" >/dev/null || fail "accepted requires=${v}"
	done
	! _bulkhead_source_requires "$(manifest_dir 'other=2\n')" >/dev/null || fail "accepted a manifest without requires"
	! _bulkhead_source_requires "${SANDBOX}/nowhere" >/dev/null || fail "accepted a missing manifest"
}

# --- bulkhead source add ---------------------------------------------------------------

test_source_add_accepts_major_only() {
	assert_status 0 add_source_requiring majonly "$(installed_part 1)"
	assert_out_contains "ok (needs $(installed_part 1))"
}

test_source_add_refuses_newer_patch() {
	local newer
	newer="$(installed_part 1).$(installed_part 2).$(( $(installed_part 3) + 1 ))"
	assert_status 1 add_source_requiring newer "${newer}"
	assert_out_contains "incompatible (needs ${newer})"
	[ ! -e "${SOURCES_DIR}/newer" ] || fail "the refused clone was kept"
}

test_source_add_refuses_prerelease() {
	assert_status 1 add_source_requiring pre "$(installed_part 1).0.0-rc.1"
	assert_out_contains "invalid"
	[ ! -e "${SOURCES_DIR}/pre" ] || fail "the refused clone was kept"
}

run_tests
