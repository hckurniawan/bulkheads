#!/bin/bash
# Tests that pin bulkhead's on-disk layout. Existing installs already have data and
# source clones at these paths, and their links point into them, so moving one silently
# breaks every install: `bulkhead rm` refuses links into the old sources folder, and
# `source ls`/`add` stop finding the clones. That's why this file spells the documented
# paths out instead of reading them from lib/core.sh, and the only test file the
# hardcoded-path lint check allows to. Moving a path on purpose means changing it here,
# in AGENTS.md and README.md, moving existing installs, and a MAJOR bump.
set -e

. "$(cd -P "$(dirname "$0")" && pwd)/lib.sh"

# The documented locations, under the sandbox HOME.
documented_data_dir() { printf '%s' "${HOME}/bulkhead-data"; }
documented_sources_dir() { printf '%s' "${HOME}/bulkhead-data/.bulkhead/sources"; }

# Prints one of lib/core.sh's globals as it is under the sandbox HOME.
core_value() {
	( . "${REPO_DIR}/lib/core.sh" && eval "printf '%s' \"\${$1}\"" )
}

test_data_dir_is_documented_location() {
	[ "$(core_value BULKHEAD_DATA_DIR)" = "$(documented_data_dir)" ] \
		|| fail "BULKHEAD_DATA_DIR is $(core_value BULKHEAD_DATA_DIR), expected $(documented_data_dir)"
}

test_sources_dir_is_documented_location() {
	[ "$(core_value BULKHEAD_SOURCES_DIR)" = "$(documented_sources_dir)" ] \
		|| fail "BULKHEAD_SOURCES_DIR is $(core_value BULKHEAD_SOURCES_DIR), expected $(documented_sources_dir)"
}

# An install made before any change: the source is cloned and its wrapper linked by
# hand, at the documented paths, without going through `bulkhead source add`/`add`.
test_existing_source_install_still_works() {
	local repo clone
	repo="${SANDBOX}/personal-repo"
	clone="$(documented_sources_dir)/personal"

	mkdir -p "${repo}/bin"
	printf 'requires=%s\n' "$(current_requires)" > "${repo}/bulkhead-source"
	printf '#!/bin/bash\necho yt-download-video\n' > "${repo}/bin/yt-download-video"
	chmod +x "${repo}/bin/yt-download-video"
	git -C "${repo}" init -q
	git -C "${repo}" add -A
	git -C "${repo}" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
	mkdir -p "$(documented_sources_dir)"
	git clone -q "${repo}" "${clone}"
	ln -s "${clone}/bin/yt-download-video" "${BIN}/yt-download-video"

	assert_status 0 bulkhead source ls
	assert_out_contains "personal"
	assert_status 0 bulkhead add yt-download-video </dev/null
	assert_out_contains "Already linked"
	assert_status 0 bulkhead rm yt-download-video </dev/null
	assert_no_link yt-download-video
}

run_tests
