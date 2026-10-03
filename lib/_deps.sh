# bulkhead — wrapper dependencies: the `# bulkhead-needs:` header and what it implies.
#
# A manager-only part: the leading `_` in the file name means lib/common.sh never loads
# it, and only bin/bulkhead sources it, so wrappers never see these functions. It may use
# core.sh, and calls neither `container` nor curl. Every function only reads and answers;
# prompting and linking belong to bin/bulkhead.

# Part of bulkhead's manager. Source-only — this file defines functions and variables and
# executes nothing.
if [ -n "${_BULKHEAD_DEPS_SH:-}" ]; then return 0; fi
_BULKHEAD_DEPS_SH=1

# Resolve this part's own directory so it can pull in what it depends on, making it
# sourceable on its own (handy for testing). BASH_SOURCE is the only reliable handle.
: "${BULKHEAD_LIB_DIR:=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
. "${BULKHEAD_LIB_DIR}/core.sh"

# The core wrappers' directory, as a physical path, matching bin/bulkhead's BIN_DIR.
_DEPS_CORE_BIN="$(cd -P "${BULKHEAD_LIB_DIR}/../bin" && pwd)"

# Prints the names a wrapper declares on `# bulkhead-needs:` lines, one per line. Only the
# leading comment block is read (it ends at the first line not starting with `#`), and
# the file is never run, since a source wrapper comes from another repository.
# Returns 1 when the wrapper can't be read.
# Internal: not part of the public API, so sources must not call it (see AGENTS.md).
_deps_needs() {
	local line rest word words
	[ -f "$1" ] && [ -r "$1" ] || return 1

	while IFS= read -r line || [ -n "${line}" ]; do
		case "${line}" in
			"# bulkhead-needs:"*)
				rest="${line#"# bulkhead-needs:"}"
				# read -a splits on whitespace without glob expansion.
				read -r -a words <<< "${rest}"
				for word in "${words[@]}"; do
					printf '%s\n' "${word}"
				done
				;;
			"#"*) ;;
			*) break ;;
		esac
	done < "$1"
}

# Prints the bin/ directory of the repository a wrapper path belongs to: the core bin/,
# or ${BULKHEAD_SOURCES_DIR}/<source>/bin. Returns 1 for a path in neither.
# Internal: not part of the public API, so sources must not call it (see AGENTS.md).
_deps_repo_bin() {
	local dir rest
	dir="$(dirname "$1")"

	if [ "${dir}" = "${_DEPS_CORE_BIN}" ]; then
		printf '%s' "${dir}"
		return 0
	fi
	case "${dir}" in
		"${BULKHEAD_SOURCES_DIR}"/*/bin)
			rest="${dir#"${BULKHEAD_SOURCES_DIR}/"}"
			case "${rest}" in */*/*) return 1 ;; esac
			printf '%s' "${dir}"
			return 0
			;;
	esac
	return 1
}

# Returns 0 when a name is safe as one path component: not empty, no leading dot, no
# slash (the rule data_dir applies).
# Internal: not part of the public API, so sources must not call it (see AGENTS.md).
_deps_valid_name() {
	case "$1" in
		"" | .* | */*) return 1 ;;
	esac
}

# Prints the path of the wrapper a need names, as seen from the wrapper that declared
# it. A bare name is looked up in the declaring wrapper's own repository only;
# `core/<name>` and `<source>/<name>` reach another one. Resolution is exact, so a need
# can never be ambiguous or shadowed. Returns 1 when the name is unsafe, names the
# manager, or the wrapper or source doesn't exist.
# Internal: not part of the public API, so sources must not call it (see AGENTS.md).
_deps_resolve() {
	local from need bin name src
	from="$1"
	need="$2"

	case "${need}" in
		core/*)
			bin="${_DEPS_CORE_BIN}"
			name="${need#core/}"
			;;
		*/*)
			src="${need%%/*}"
			name="${need#*/}"
			_deps_valid_name "${src}" || return 1
			bin="${BULKHEAD_SOURCES_DIR}/${src}/bin"
			;;
		*)
			bin="$(_deps_repo_bin "${from}")" || return 1
			name="${need}"
			;;
	esac

	_deps_valid_name "${name}" || return 1
	[ "${name}" != "bulkhead" ] || return 1
	[ -f "${bin}/${name}" ] || return 1
	printf '%s' "${bin}/${name}"
}

# Returns 0 when any symlink in <bin-dir> points at <wrapper-path>, so an alias (e.g.
# gpg-work) satisfies a need for the wrapper it links to.
# Internal: not part of the public API, so sources must not call it (see AGENTS.md).
_deps_is_linked() {
	local link
	for link in "$1"/*; do
		[ -h "${link}" ] || continue
		[ "$(readlink "${link}")" = "$2" ] && return 0
	done
	return 1
}

# Returns 0 when the first argument equals any of the rest.
# Internal: not part of the public API, so sources must not call it (see AGENTS.md).
_deps_contains() {
	local needle item
	needle="$1"
	shift
	for item in "$@"; do
		[ "${item}" = "${needle}" ] && return 0
	done
	return 1
}

# Prints the wrappers <wrapper-path> needs that have no link in <bin-dir>, transitively,
# deepest first, so linking them in order never leaves a need unmet. Needs that are
# already linked are still walked, so a missing need further down is found too. A cycle
# ends at a wrapper already visited. Returns 1, with an error naming the need and the
# wrapper that declared it, when any need doesn't resolve; nothing is printed then.
# Internal: not part of the public API, so sources must not call it (see AGENTS.md).
_deps_missing() {
	local dep
	_DEPS_VISITED=()
	_DEPS_ORDER=()

	_deps_walk "$1" "$2" || return 1
	for dep in "${_DEPS_ORDER[@]}"; do
		printf '%s\n' "${dep}"
	done
}

# The depth-first walk behind _deps_missing. Reports through _DEPS_VISITED and
# _DEPS_ORDER, since Bash 3.2 has no way to return an array.
# Internal: not part of the public API, so sources must not call it (see AGENTS.md).
_deps_walk() {
	local bin_dir path needs need dep
	bin_dir="$1"
	path="$2"
	_DEPS_VISITED+=("${path}")

	if ! needs="$(_deps_needs "${path}")"; then
		log_error "Could not read ${path} to check what it needs." >&2
		return 1
	fi

	while IFS= read -r need; do
		[ -n "${need}" ] || continue
		if ! dep="$(_deps_resolve "${path}" "${need}")"; then
			log_error "$(basename "${path}") needs '${need}', which isn't a wrapper it can reach." >&2
			return 1
		fi
		_deps_contains "${dep}" "${_DEPS_VISITED[@]}" && continue
		_deps_walk "${bin_dir}" "${dep}" || return 1
		_deps_is_linked "${bin_dir}" "${dep}" || _DEPS_ORDER+=("${dep}")
	done <<< "${needs}"
}

# Prints the links in <bin-dir> whose wrapper would have a need left unmet once
# <link-path> is removed, transitively, one per line, the most dependent first so they
# can be removed in order. A need still met by another remaining link (e.g. the `gpg`
# link when an alias of gpg is removed) leaves its wrapper alone. Only links into the
# core bin/ or a source's bin/ are considered.
# Internal: not part of the public API, so sources must not call it (see AGENTS.md).
_deps_dependents() {
	local bin_dir removed changed link target need dep link2 met i
	bin_dir="$1"
	removed=("$2")
	changed=1

	while [ "${changed}" -eq 1 ]; do
		changed=0
		for link in "${bin_dir}"/*; do
			[ -h "${link}" ] || continue
			_deps_contains "${link}" "${removed[@]}" && continue
			target="$(readlink "${link}")"
			_deps_repo_bin "${target}" >/dev/null || continue

			while IFS= read -r need; do
				[ -n "${need}" ] || continue
				dep="$(_deps_resolve "${target}" "${need}")" || continue
				met=0
				for link2 in "${bin_dir}"/*; do
					[ -h "${link2}" ] || continue
					_deps_contains "${link2}" "${removed[@]}" && continue
					if [ "$(readlink "${link2}")" = "${dep}" ]; then
						met=1
						break
					fi
				done
				if [ "${met}" -eq 0 ]; then
					removed+=("${link}")
					changed=1
					break
				fi
			done <<< "$(_deps_needs "${target}" || true)"
		done
	done

	i=$(( ${#removed[@]} - 1 ))
	while [ "${i}" -ge 1 ]; do
		printf '%s\n' "${removed[${i}]}"
		i=$(( i - 1 ))
	done
}
