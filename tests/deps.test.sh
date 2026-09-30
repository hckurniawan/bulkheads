#!/bin/bash
# Tests for wrapper dependencies: `bulkhead add`/`rm` resolving `# bulkhead-needs:`, and
# the lib/_deps.sh functions on their own.
set -e

. "$(cd -P "$(dirname "$0")" && pwd)/lib.sh"

# --- bulkhead add ------------------------------------------------------------------

test_add_without_terminal_or_yes_stops() {
	assert_status 1 bulkhead add git-secret </dev/null
	assert_out_contains "rerun with -y"
	assert_no_link gpg
	assert_no_link git-secret
}

test_add_yes_links_both_without_asking() {
	assert_status 0 bulkhead add git-secret -y </dev/null
	assert_out_contains "git-secret needs these wrappers"
	assert_link gpg "${REPO_DIR}/bin/gpg"
	assert_link git-secret "${REPO_DIR}/bin/git-secret"
	# gpg is linked before git-secret.
	case "${OUT}" in
		*"bin/gpg ->"*"bin/git-secret ->"*) ;;
		*) fail "gpg wasn't linked first; output:
${OUT}" ;;
	esac
}

test_add_yes_flag_may_come_first() {
	assert_status 0 bulkhead add --yes git-secret </dev/null
	assert_link gpg "${REPO_DIR}/bin/gpg"
}

test_add_alias_satisfies_need() {
	assert_status 0 bulkhead add gpg gpg-work
	assert_status 0 bulkhead add git-secret </dev/null
	assert_link git-secret "${REPO_DIR}/bin/git-secret"
	assert_no_link gpg
}

test_add_blocked_dependency_name_links_nothing() {
	echo "not a link" > "${BIN}/gpg"
	assert_status 1 bulkhead add git-secret -y </dev/null
	assert_out_contains "already taken"
	assert_no_link git-secret
	[ "$(cat "${BIN}/gpg")" = "not a link" ] || fail "the file at bin/gpg was changed"
}

test_add_repairs_missing_dependency_of_linked_wrapper() {
	ln -s "${REPO_DIR}/bin/git-secret" "${BIN}/git-secret"
	assert_status 0 bulkhead add git-secret -y </dev/null
	assert_link gpg "${REPO_DIR}/bin/gpg"
}

test_add_already_linked_with_dependencies_met() {
	assert_status 0 bulkhead add git-secret -y </dev/null
	assert_status 0 bulkhead add git-secret </dev/null
	assert_out_contains "Already linked"
}

test_add_without_needs_is_unchanged() {
	assert_status 0 bulkhead add terraform </dev/null
	assert_link terraform "${REPO_DIR}/bin/terraform"
	case "${OUT}" in
		"Linked: ${BIN}/terraform -> ${REPO_DIR}/bin/terraform") ;;
		*) fail "unexpected output: ${OUT}" ;;
	esac
}

# --- bulkhead add, fixture source ------------------------------------------------------

test_add_chain_links_deepest_first() {
	fixture_source fx
	assert_status 0 bulkhead add a -y </dev/null
	src="${SOURCES_DIR}/fx/bin"
	assert_link a "${src}/a"
	assert_link b "${src}/b"
	assert_link c "${src}/c"
	case "${OUT}" in
		*"bin/c ->"*"bin/b ->"*"bin/a ->"*) ;;
		*) fail "not linked c, b, a; output:
${OUT}" ;;
	esac
}

test_add_cycle_terminates() {
	fixture_source fx
	assert_status 0 bulkhead add x -y </dev/null
	assert_link x "${SOURCES_DIR}/fx/bin/x"
	assert_link y "${SOURCES_DIR}/fx/bin/y"
}

test_add_unresolvable_need_links_nothing() {
	fixture_source fx
	assert_status 1 bulkhead add bad -y </dev/null
	assert_out_contains "needs 'nosuch'"
	assert_no_link bad
}

test_add_qualified_core_need() {
	fixture_source fx
	assert_status 0 bulkhead add uses-core -y </dev/null
	assert_link gpg "${REPO_DIR}/bin/gpg"
}

# --- bulkhead rm -------------------------------------------------------------------

test_rm_yes_removes_dependents_first() {
	bulkhead add git-secret -y >/dev/null </dev/null
	assert_status 0 bulkhead rm gpg -y </dev/null
	assert_out_contains "These wrappers depend on gpg"
	assert_no_link gpg
	assert_no_link git-secret
	case "${OUT}" in
		*"bin/git-secret ("*"bin/gpg ("*) ;;
		*) fail "git-secret wasn't removed first; output:
${OUT}" ;;
	esac
}

test_rm_without_terminal_or_yes_stops() {
	bulkhead add git-secret -y >/dev/null </dev/null
	assert_status 1 bulkhead rm gpg </dev/null
	assert_link gpg "${REPO_DIR}/bin/gpg"
	assert_link git-secret "${REPO_DIR}/bin/git-secret"
}

test_rm_alias_while_need_still_met() {
	bulkhead add git-secret -y >/dev/null </dev/null
	bulkhead add gpg gpg-work >/dev/null
	assert_status 0 bulkhead rm gpg-work </dev/null
	assert_link git-secret "${REPO_DIR}/bin/git-secret"
	assert_link gpg "${REPO_DIR}/bin/gpg"
}

test_rm_chain_removes_transitive_dependents() {
	fixture_source fx
	bulkhead add a -y >/dev/null </dev/null
	assert_status 0 bulkhead rm c -y </dev/null
	assert_out_contains "These wrappers depend on c"
	assert_no_link a
	assert_no_link b
	assert_no_link c
	# Most dependent first.
	case "${OUT}" in
		*"bin/a ("*"bin/b ("*"bin/c ("*) ;;
		*) fail "not removed a, b, c; output:
${OUT}" ;;
	esac
}

test_rm_without_dependents_is_unchanged() {
	bulkhead add terraform >/dev/null
	assert_status 0 bulkhead rm terraform </dev/null
	assert_no_link terraform
}

# --- lib/_deps.sh on its own ------------------------------------------------------

test_unit_needs_reads_header() {
	. "${REPO_DIR}/lib/_deps.sh"
	[ "$(_deps_needs "${REPO_DIR}/bin/git-secret")" = "gpg" ] || fail "git-secret's needs aren't 'gpg'"
	[ -z "$(_deps_needs "${REPO_DIR}/bin/terraform")" ] || fail "terraform declares needs"
}

test_unit_resolve() {
	. "${REPO_DIR}/lib/_deps.sh"
	[ "$(_deps_resolve "${REPO_DIR}/bin/git-secret" gpg)" = "${REPO_DIR}/bin/gpg" ] || fail "gpg"
	[ "$(_deps_resolve "${REPO_DIR}/bin/git-secret" core/gpg)" = "${REPO_DIR}/bin/gpg" ] || fail "core/gpg"
	! _deps_resolve "${REPO_DIR}/bin/git-secret" ../x >/dev/null || fail "../x resolved"
	! _deps_resolve "${REPO_DIR}/bin/git-secret" bulkhead >/dev/null || fail "bulkhead resolved"
	! _deps_resolve "${REPO_DIR}/bin/git-secret" nosuch >/dev/null || fail "nosuch resolved"
	! _deps_resolve "${REPO_DIR}/bin/git-secret" nosrc/x >/dev/null || fail "nosrc/x resolved"
}

test_unit_is_linked_counts_alias() {
	. "${REPO_DIR}/lib/_deps.sh"
	! _deps_is_linked "${BIN}" "${REPO_DIR}/bin/gpg" || fail "linked before any link"
	ln -s "${REPO_DIR}/bin/gpg" "${BIN}/gpg-work"
	_deps_is_linked "${BIN}" "${REPO_DIR}/bin/gpg" || fail "alias not counted"
}

test_unit_loader_does_not_load_deps() {
	# Wrappers load lib/common.sh; the manager-only part must not come with it.
	( . "${REPO_DIR}/lib/common.sh"; ! type _deps_needs >/dev/null 2>&1 ) \
		|| fail "lib/common.sh defines _deps_needs"
}

run_tests
