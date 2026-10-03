#!/bin/bash
# Lint checks: syntax, plus the AGENTS.md rules that can be checked with grep, so a
# change that breaks one fails `make test` instead of waiting for review.
set -e

. "$(cd -P "$(dirname "$0")" && pwd)/lib.sh"

# The internal functions' names before they took a `_` prefix.
OLD_INTERNAL='container_start_system|container_build_context|image_slug|image_stamp_path|image_stamp_stale|image_script_newer|image_exists|image_remove|registry_digest_changed|bulkhead_version_satisfies|bulkhead_source_requires'

test_syntax() {
	local f
	for f in "${REPO_DIR}"/bin/* "${REPO_DIR}"/lib/*.sh "${REPO_DIR}"/install.sh \
		"${REPO_DIR}"/tests/run "${REPO_DIR}"/tests/*.sh "${REPO_DIR}"/examples/source/bin/*; do
		bash -n "${f}" || fail "syntax error in ${f}"
	done
}

test_registry_never_calls_container() {
	! grep -n '^[^#]*container ' "${REPO_DIR}/lib/registry.sh" || fail "lib/registry.sh calls container"
}

test_core_and_deps_call_neither_container_nor_curl() {
	local f
	for f in core.sh _deps.sh; do
		! grep -nE '^[^#]*(container|curl) ' "${REPO_DIR}/lib/${f}" || fail "lib/${f} calls container or curl"
	done
}

test_loader_never_loads_manager_only_parts() {
	local parts
	parts="$(sed -n 's/^for _bulkhead_part in \(.*\); do$/\1/p' "${REPO_DIR}/lib/common.sh")"
	[ -n "${parts}" ] || fail "can't find the loader's part list in lib/common.sh"
	case " ${parts} " in
		*" _"*) fail "lib/common.sh loads a manager-only part: ${parts}" ;;
	esac
	! grep -n '^[^#]*_deps' "${REPO_DIR}/lib/common.sh" || fail "lib/common.sh mentions _deps outside a comment"
}

test_no_old_internal_names() {
	! grep -rnwE "${OLD_INTERNAL}" "${REPO_DIR}/lib" "${REPO_DIR}/bin" "${REPO_DIR}/examples" \
		"${REPO_DIR}/AGENTS.md" "${REPO_DIR}/README.md" "${REPO_DIR}/docs" \
		|| fail "an old internal name (without its _ prefix) is still used"
}

test_example_source_uses_only_public_api() {
	! grep -nE '(^|[^A-Za-z0-9_])_(container|image|registry|bulkhead|deps|args)_' "${REPO_DIR}"/examples/source/bin/* \
		|| fail "examples/source calls an internal function"
	! grep -n 'BULKHEAD_HOME}/bin/' "${REPO_DIR}"/examples/source/bin/* \
		|| fail "examples/source refers to the core bin/"
}

test_internal_functions_are_marked() {
	local f line prev
	for f in "${REPO_DIR}"/lib/*.sh; do
		prev=""
		while IFS= read -r line; do
			case "${line}" in
				_[a-z]*"() {"*)
					case "${prev}" in
						"# Internal:"*) ;;
						*) fail "${f##*/}: ${line%%(*} has no '# Internal:' line above it" ;;
					esac
					;;
			esac
			prev="${line}"
		done < "${f}"
	done
}

test_api_doc_lists_every_public_function() {
	local code doc
	code="$(grep -hoE '^[a-z][a-z_]*\(\)' "${REPO_DIR}"/lib/[a-z]*.sh | tr -d '()' | sort)"
	doc="$(sed -n 's/^#### `\([a-z][a-z_]*\)`$/\1/p' "${REPO_DIR}/docs/api.md" | sort)"
	[ "${code}" = "${doc}" ] || fail "public functions in lib/ and docs/api.md differ:
$(diff <(printf '%s\n' "${code}") <(printf '%s\n' "${doc}") | sed 's/^</  lib only:/; s/^>/  doc only:/' | grep only)"
}

test_api_doc_globals_exist_in_lib() {
	local name
	for name in $(sed -n 's/^| `\([A-Z][A-Z_]*\)` |.*/\1/p' "${REPO_DIR}/docs/api.md"); do
		grep -qE "(^|[^A-Za-z0-9_])${name}(\+)?=" "${REPO_DIR}"/lib/[a-z]*.sh \
			|| fail "docs/api.md documents ${name}, which nothing in lib/ sets"
	done
}

test_paths_come_from_variables() {
	# Only lib/core.sh spells these paths; everything else uses BULKHEAD_DATA_DIR and
	# BULKHEAD_SOURCES_DIR, so moving one is a one-line change. Comments may name them.
	# tests/layout.test.sh is the exception: it pins the documented paths on purpose.
	! grep -nE '^[^#]*(bulkhead-data|\.bulkhead/|bulkhead-sources)' \
		"${REPO_DIR}"/bin/* $(ls "${REPO_DIR}"/lib/*.sh | grep -v '/core\.sh$') \
		$(ls "${REPO_DIR}"/tests/* | grep -v '/layout\.test\.sh$') \
		|| fail "a data or sources path is hardcoded instead of using its variable"
}

run_tests
