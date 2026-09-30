# AGENTS.md

Guidance for AI coding agents working in this repository. README.md and the user guides in `docs/` are the user-facing documentation; this file holds the rules, the reasons behind them, and the implementation details.

## Overview

`bulkhead` is a set of Bash wrapper scripts in `bin/`. Each one runs a developer CLI tool in a disposable container using Apple's `container` CLI (Apple silicon, macOS 26+). **Docker is not used anywhere.** `container` is the only engine and there is no fallback. There is no build or package step: the `Makefile` only has `test` and `install`, which call `tests/run` and `install.sh`. Each file in `bin/` is an independent executable.

- `bin/bulkhead`: the manager. It symlinks wrappers from the clone, or from a registered source, into `~/.local/bin`, and `bulkhead home` prints the clone root.
- `bin/<tool>`: the wrappers. They find the shared library through `bulkhead home`, so `bulkhead` must be on `PATH`. This is a hard requirement with no local fallback.
- `lib/common.sh`: a loader that sources five layered parts (see [The shared library](#the-shared-library)), then checks a source wrapper's compatibility.
- `lib/_deps.sh`: a manager-only part, sourced only by `bin/bulkhead`, that reads wrappers' `# bulkhead-needs:` headers.
- `docs/api.md`: the public API reference for wrapper authors (see [Versioning and the public API](#versioning-and-the-public-api)).
- `docs/sources.md`, `docs/images.md`, `docs/gpg.md`: user guides the README links to, for adding sources, how images are rebuilt, and git-secret's keyrings.
- `tests/`: the test suite (see [Tests](#tests)).
- **Sources**: child git repositories of extra wrappers, kept out of this repository (see [Sources](#sources)). This repository owns all the machinery; a source holds only wrappers and a manifest.
- `install.sh`: a standalone bootstrap installer.

**Name.** Before 2.0.0 the project was called `docklet`, a name that suggested Docker. 2.0.0 is a clean break: nothing reads, moves or cleans up the old `~/docklet-data`, `docklet/*` images or `docklet` link. Don't reintroduce the old name or add migration code for it.

## Wrappers

Every wrapper also mounts the working directory: at `/work` for `claude`, and at `/data` for the others. Wrappers without a `DATA_DIR` keep nothing between runs.

`bin/claude` is the reference for the build pattern and `bin/terraform` for the official-image pattern.

**`yq`** runs the official `mikefarah/yq` image, with two exceptions to the rules below:
- **Tag `4`, not `major.minor`.** The image publishes only `4` and full `4.x.y` tags, so the pin is the major version. The `base` check therefore adopts new minor releases as well as patches. A new major is still a hand edit.
- `-w /data` overrides the image's `/workdir`.

**`gpg` and `git-secret` share one image**, `bulkhead/gpg`, so git-secret always runs the exact gpg the `gpg` wrapper runs, against a `gpg` keyring.
- `bin/gpg` owns everything: the Dockerfile, `update`, the mounts and the run. Its image installs Alpine's `gnupg` plus git-secret and git-secret's dependencies.
- `bin/git-secret` only resolves the keyring and runs `BULKHEAD_GPG_TOOL=git-secret BULKHEAD_GPG_KEYRING="${KEYRING}" exec "${BULKHEAD_HOME}/bin/gpg" "$@"`. It doesn't source the lib or define a Dockerfile, and it never builds an image of its own.
  - It runs the gpg script by its path in the clone, so with no keyring set, `basename "$0"` is `gpg` and the keyring is `~/bulkhead-data/gpg`, whether or not `gpg` was added to `~/.local/bin`.
  - It still declares `# bulkhead-needs: gpg`. git-secret runs without the link, but its keys can only be imported and managed through the `gpg` wrapper.
  - `bin/gpg` is also the `$0` that the script-change check compares against. Editing only `bin/git-secret` never rebuilds the image, and nothing in it needs to.
  - `git-secret update` reaches `bin/gpg`'s `update` and rebuilds the shared image. `git-secret -- update` reaches git-secret itself.
- `BULKHEAD_GPG_TOOL` defaults to `gpg`, and `bin/gpg` exits on any value other than `gpg` or `git-secret`. The container is run with the tool name as its first argument.
- **The repository picks the keyring, not the wrapper's name.** How users set it up is in [`docs/gpg.md`](docs/gpg.md). Aliases of `git-secret` add nothing, since the keyring doesn't depend on its name.
  - `bin/git-secret` reads `bulkhead.gpgKeyring` with `git config --get` on the Mac, from the current directory. Exit 1 means the key isn't set, and the `gpg` keyring is used. Any other failure is fatal rather than a quiet fallback to another keyring.
  - `bin/gpg` passes a non-empty `BULKHEAD_GPG_KEYRING` to `data_dir <name>`, whose name check keeps the path inside `BULKHEAD_DATA_DIR` and off `.bulkhead`.
  - A named keyring must already exist. `bin/gpg` exits instead of creating it, because an empty keyring can't decrypt anything.
- The data folder is mounted at `/root/.gnupg` (gpg's default home), with no `GNUPGHOME`, and `chmod 700`ed, since gpg warns about a home directory other users can read.
- The entrypoint is generic:
  ```dockerfile
  ENTRYPOINT [ "/bin/sh", "-c", "mkdir -p -m 700 /run/user/0 && exec \"$@\"", "entrypoint" ]
  ```
  When `/run/user/0` exists, GnuPG puts every socket (gpg-agent, dirmngr, keyboxd) under `/run/user/0/gnupg` instead of the bind-mounted home directory. This replaces per-socket `%Assuan%` redirect files, which would miss sockets and leave files in the keyring folder. The directory is created at run time in case `/run` is a fresh tmpfs.
- git-secret is a pinned release built from its GitHub source tarball and verified by SHA-256, so `GIT_SECRET_VERSION` and `GIT_SECRET_SHA256` are bumped together by hand. Upstream's `make build` only concatenates shell files, so `make` is a virtual package removed in the same layer, with no second build stage.
- Only the working directory is mounted, so git-secret must be run from the repository root, where `.git` is visible. The image sets `safe.directory /data`.

## The wrapper pattern

Preserve this structure when adding or editing a wrapper:

1. **Preamble.** Start with these two lines:
   ```sh
   BULKHEAD_HOME="$(bulkhead home)" || { echo "bulkhead not found on PATH; install bulkhead first" >&2; exit 1; }
   . "${BULKHEAD_HOME}/lib/common.sh"
   ```
   The `||` keeps it `set -e`-safe. Always source `lib/common.sh`, never a single part, so the whole API is available and the layout can change without touching `bin/`.

   **Dependencies.** A wrapper that is incomplete unless another wrapper is linked too declares it with a `# bulkhead-needs: <name>…` line in its leading comment block (the comment lines before the first non-comment line). Name resolution is in [`docs/api.md`](docs/api.md#wrapper-headers); what `add` and `rm` do with it is under [Manager and installer](#manager-and-installer).
   - Declare a need only when the user can't work without the other wrapper's link. Running another wrapper by its path, or using its data, doesn't on its own make it a need.

2. **Variables.** Set `IMAGE`. If the tool keeps state, also set `DATA_DIR="$(data_dir)"` ([`data_dir`](docs/api.md#data_dir)). Keep it based on the invoked name, never on the resolved path, so an alias symlink gets its own isolated state. Pass a name only to use another wrapper's data (today only `gpg`, for git-secret's keyring).

3. **Decide whether to build.** Use exactly one line, never a hand-rolled check:
   ```sh
   image_needs_build "${IMAGE}" missing              && build   # everything pinned
   image_needs_build "${IMAGE}" age  "${PERIOD}"     && build   # installs "latest" on a pinned base
   image_needs_build "${IMAGE}" base "${BASE_IMAGE}" && build   # base tag moves
   ```
   - What each policy checks, what it reports and when it exits: [`image_needs_build`](docs/api.md#image_needs_build). User-facing summary: [`docs/images.md`](docs/images.md).
   - The script check (`_image_script_newer`) is what makes a Dockerfile change arriving through `bulkhead update` take effect on the next run. `stat -L -f %m "$0"` follows the `~/.local/bin` symlink to the clone file. With no `built` stamp there is nothing to compare, so official-image wrappers are never affected. The policy's own check runs first, so a moved base is still reported as `base`.
   - Under `base`, the check time is recorded even when Docker Hub is unreachable, so an outage can't make every run call Docker Hub.
   - Misuse **exits** rather than returning, so a caller bug is never read as "no build needed".

4. **Build.** The wrapper's builder is named `build` and always builds; the decision belongs to `image_needs_build`. Never name it `image_build`: that would shadow the lib's builder and recurse forever.
   - Pipe the Dockerfile to [`image_build`](docs/api.md#image_build) `"${IMAGE}" [flags]` as an inline heredoc. There are no Dockerfiles on disk.
   - Why `image_build` passes what it does to `container build`:
     - `-t`, since an untagged image gets a UUID name.
     - An empty build context, since nothing is `COPY`d from the host and `container` syncs the context into the builder VM.
     - The Dockerfile by path. `-f -` (stdin) only landed upstream on 2025-11-18 ([apple/container#827](https://github.com/apple/container/pull/827)), after the installed version, so the heredoc is spooled to a temporary file.
   - Under the `base` policy, `build` must end with [`image_record_base`](docs/api.md#image_record_base), so a failed build never marks the base as adopted.

5. **Wrapper commands.** A wrapper that has its own command (today only `update`) parses its arguments with `args_parse`, never by hand:
   ```sh
   args_parse update "$@"
   container_require
   if [ "${ARGS_COMMAND}" = "update" ]; then
   	image_update "${IMAGE}" "the latest yt-dlp release" || exit 1
   	exit 0
   fi
   ```
   - The parsing rules are in [`args_parse`](docs/api.md#args_parse), and the return values in [`image_update`](docs/api.md#image_update).
   - Neither `args_parse` nor `image_update` exits on the wrapper's behalf; the wrapper owns its exit status.

6. **Run.**
   - `mkdir -p` each mount source first.
   - Then run `container run ${tty_flag} --init --rm` with the mounts, passing `"${FORWARD_ARGS[@]}"` (or `"$@"` when there's no `args_parse`) to the entrypoint.
   - **Check all three flags on every wrapper, new or edited: `${tty_flag}`, `--init` and `--rm`.** They're required unless a wrapper has a real reason not to use one. An exception must be explained in a comment at the `container run` line and noted in the Wrappers section.
     - `--rm` removes the container when it exits, so nothing but the mounts survives a run.
     - `--init` runs a minimal init as PID 1, which passes signals such as Ctrl-C on to the tool and reaps exited child processes. Without it, the tool is PID 1 and may ignore those signals.
     - `${tty_flag}` is set as described below.
     - A wrapper that hands off to another wrapper instead of calling `container run` (today only `git-secret`, through `bin/gpg`) inherits that wrapper's flags. Check them there.
   - Use `-i`, adding `-t` only when both stdin and stdout are terminals:
     ```sh
     tty_flag="-i"
     [ -t 0 ] && [ -t 1 ] && tty_flag="-it"
     ```
     A TTY turns output newlines into CRLF, so checking stdin alone would corrupt `tool args > out` typed at a terminal. Plain `-it` is an exception, only for tools that can't work without a terminal; say why in a comment.
   - **Never pass `--user`, and don't bake a non-root `USER` into an image.** This is a consistency rule: every wrapper runs as the image's default user, which is root for every image bulkhead builds. Files written by root in the container still come back owned by the macOS user. An official image that bakes in its own non-root user keeps it (see `yq`).
     - **What's known about users and mounts** (checked 2026-09-30):
       - `container run` has `-u, --user <name|uid[:gid]>`, `--uid` and `--gid` ([command reference](https://github.com/apple/container/blob/main/docs/command-reference.md)).
       - There's no UID/GID mapping for bind mounts. That's an open feature request, [apple/container#165](https://github.com/apple/container/issues/165), with no maintainer response.
       - Apple doesn't document how mounted files' ownership appears inside the container.
     - **Don't claim that a non-root user can't write to a mount.** Nothing documents that, and the `yq` image's non-root `USER yq` was tested writing with `yq -i` and succeeded. An earlier version of this rule stated that claim as fact. How ownership appears inside the guest (e.g. `ls -ln /data`) hasn't been checked.

## Choosing an image

- **Prefer an official Docker Hub image** when the tool publishes one. Run it directly, with no Dockerfile, since `container run` pulls it when it's missing.
- **Pin a `major.minor` tag**, never `:latest`. Docker Hub moves that tag to each new patch release, so the pin tracks patches. A new minor or major is a hand edit; nothing adopts one automatically.
- **Track the tag with the `base` policy**, using the image as its own base:
  ```sh
  image_needs_build "${IMAGE}" base "${IMAGE}" && pull
  ```
  - `container run` never re-pulls a tag it already has, so a moved tag is detected by its Docker Hub digest. When it changed, `image_needs_build` removes the stale local copy and `container run` pulls the current one.
  - The wrapper's `pull` only calls `image_record_base "${IMAGE}" "${IMAGE}"`. There is nothing to build.
  - The wrapper's `update` is the usual `image_update "${IMAGE}" "…"`, which removes the image so the next run pulls it.
- **Use the build pattern only when necessary**: when there's no official image, when the tool installs through npm, pip, gem or an install script, or when significant post-install setup is needed.
  - Name the image `bulkhead/<script-name>` so `IMAGE` matches the wrapper's filename.
  - Pick the base by what drifts: a moving base tag gets `base`; a pinned base that installs "latest" gets `age`; fully pinned gets `missing`.
- **Building from a source tarball** (today git-secret in `bin/gpg`, and `unrar`):
  - Pin a `<TOOL>_VERSION` and the tarball's `<TOOL>_SHA256`, and bump them together by hand. The build uses the `missing` policy.
  - Download the GitHub tag tarball (`…/archive/refs/tags/v${VERSION}.tar.gz`) into `/tmp` with Alpine's `wget`, and check it with `sha256sum -c -` before unpacking. The tarball unpacks to `<repo>-<version>/`, without the `v`, so build with `make -C "<repo>-${VERSION}"`.
  - Install build tools as `--virtual .build-deps` and `apk del` them in the same `RUN`, rather than using a second build stage. Install any runtime library the tool links against (e.g. `libstdc++` for unrar) explicitly first, so removing the build tools doesn't remove it too.
  - `unrar` builds from a mirror of RARLAB's source, [hckurniawan/unrar](https://github.com/hckurniawan/unrar), so a new release has to be tagged there first.
- `container build` rejects Dockerfiles larger than 16 KiB on stdin. `image_build` passes the file by path, so it's not known whether the limit still applies. The current Dockerfiles are far below it either way.

## The shared library

`lib/common.sh` resolves its own directory with `cd -P`/`dirname`, as `bin/bulkhead` does (never `readlink -f`, which is GNU-only). It sources the parts in this order. The last row is the one manager-only part, which the loader never sources:

| Part | Holds | May use |
|---|---|---|
| `core.sh` | `BULKHEAD_VERSION`, `BULKHEAD_DATA_DIR` (`~/bulkhead-data`), `BULKHEAD_SYSTEM_DIR` (`…/.bulkhead`), `BULKHEAD_SOURCES_DIR` (`…/.bulkhead/sources`), `STALENESS_PERIOD` (1 day), `log_info`/`log_warn`/`log_error`, `data_dir`, `_semver_parse`, `_semver_num_cmp`, `_semver_compare`, `_bulkhead_version_satisfies`, `_bulkhead_source_requires` | nothing |
| `args.sh` | `args_parse` | core |
| `engine.sh` | `container_require`, `_container_start_system`, `container_builder_reset`, `_container_build_context` | core |
| `registry.sh` | `_registry_digest_changed` | core |
| `image.sh` | `_image_exists`, `_image_remove`, `image_build`, `image_update`, `image_needs_build`, `image_record_base`, `_image_script_newer`, `_image_slug`, `_image_stamp_path`, `_image_stamp_stale` | core, engine, registry |
| `_deps.sh` (manager-only) | `_deps_needs`, `_deps_resolve`, `_deps_is_linked`, `_deps_missing`, `_deps_dependents` and their helpers | core |

**Keep the layering intact and greppable:**
- `registry.sh` never calls `container`. Docker Hub is the registry `container` pulls from, not the Docker engine, which is why this code survived the removal of Docker. `grep -n '^[^#]*container ' lib/registry.sh` must print nothing.
- `core.sh` and `_deps.sh` call neither `container` nor `curl`.
- No part depends on a layer above it. That's why `image_build` lives in `image.sh`: it uses `_image_exists` and writes stamps.
- A new helper goes in the lowest layer that can hold it. Needing a higher layer means the helper belongs higher up; it's not a reason to relax the rule. A new part must be added to the loader's `for` list, unless it is manager-only.
- **A manager-only part is named `lib/_<part>.sh`.** It holds code that only `bin/bulkhead` needs, `bin/bulkhead` is the only thing that sources it, and the loader never lists it, so wrappers never see its functions. All its functions are internal.
- Every part has a `_BULKHEAD_<PART>_SH` include guard and sources its own dependencies, so one layer can be loaded on its own. For example, `. lib/registry.sh` works with no `container` installed, for testing.
- Parts are source-only: they define functions and variables, never execute anything, and never `set -e`. Run-time setup such as `mkdir -p` goes inside functions.
- The loader, not a part, runs the source compatibility check after the parts load. It resolves `$0`'s symlink chain by hand; a wrapper whose real path is `${BULKHEAD_SOURCES_DIR}/<source>/bin/<x>` exits unless the source's `requires` is satisfied. Core wrappers are never checked.

## Conventions

- `set -e`, tabs, a `main` function invoked as `main "$@"`, and distinct units split into functions, each with a short comment above it.
- **Shared functions are named group first**, as `<group>_<verb>[_<object>]`: `container_require`, not `require_container`. The prefix names the owning file: `container_` → engine, `image_`, `registry_`, `args_`, `deps_` → `_deps.sh`, and `log_`, `bulkhead_` and `semver_` → core. `data_dir` is a plain accessor. Wrapper-local functions (`main`, `build`, `resolve_default_opts`) take no prefix.
- **Internal lib functions start with `_`**, as `_<group>_<verb>…` (`_image_exists`), so a call site shows that it's internal. Each also keeps an `# Internal:` line as the last line of its header comment, which says why. A lib function without the `_` is public and must be documented in `docs/api.md`.
- **Declare working variables with a bare `local a b c` line**, separate from any assignment. The lib reports through globals, so an undeclared variable can clobber a caller's. `local x="$(cmd)"` also masks `cmd`'s exit status, which the offline paths depend on.
- macOS on Apple silicon only: Bash and BSD userland, with no GNU-only flags and no Linux code paths.
- Shared helpers and paths live in `lib/`; never redefine them in a wrapper.
- **All image operations go through `image_*`.** `container image inspect` and `container image rm` appear only in `_image_exists` and `_image_remove`. The lib owns `image_build` and `image_update`, and a wrapper must not define either.
- **Never call `docker`.**
  - `container_require` gates every run. It starts the service itself through `_container_start_system`, and only a missing CLI or a service that won't come up is fatal.
  - When stdin isn't a terminal, the start passes `--enable-kernel-install`, because the first-start kernel prompt can't be answered there.
  - The build cache lives in the builder container, and there is no `builder prune`. `container_builder_reset` (`builder delete --force`) clears the cache.
- `container` command groups are singular (`container image ls`). An unknown subcommand reports a *service* error, so check the spelling before restarting anything.

## Manager and installer

**`bin/bulkhead`** has these commands: `help`, `version`, `home`, `update`, `add [-y] <name|source/name> [<alias>]`, `rm [-y] <name|alias>` and `source add|rm|ls`. There is no `refresh`; a wrapper's own `update` forces a rebuild. It sources `lib/core.sh` (inert) for the version and the source helpers, and `lib/_deps.sh` for dependencies.
- `update` is a plain `git pull` of the clone, then `git pull --ff-only` of each source, and leaves images alone. A source that fails to pull is a warning and a non-zero exit, and the rest still update. It ends by running `bulkhead source ls` in a fresh process, so the compatibility report uses the files just pulled.
- `add` links into the directory `bulkhead` was invoked from (normally `~/.local/bin`). It refuses to overwrite anything except an identical existing link.
  - A bare name is searched in the core `bin/` and every source's `bin/`, and must match exactly once. On a clash it lists the qualified names (`core/<name>`, `<source>/<name>`), so a source can never shadow a core wrapper.
  - It refuses a wrapper from a source that is incompatible or has no valid manifest.
  - **Dependencies.** It reads the wrapper's `# bulkhead-needs:` names, transitively, and works like a package manager:
    - **Preflight first, with no changes.** Every need must resolve, its source must be compatible, and each missing need's own name must be free in the bin dir. If any check fails, `add` stops with an error and links nothing.
    - Any link to a needed wrapper meets the need, including an alias. Needs that are already met are still walked, so a missing need further down is found too, and adding an already-linked wrapper repairs it.
    - Missing needs are listed and confirmed with `Add them? [Y/n]`, then linked deepest first, before the wrapper itself. If a link fails, the links made by that run are removed.
- `rm` removes only a symlink that points into the clone's `bin/` or exactly into a source's `<source>/bin/<name>`, and never touches data or images.
  - **Dependents.** The links whose wrapper would be left with a need unmet, transitively, are listed and confirmed with `Continue? [y/N]`, then removed first, most dependent first. A need still met by another link, such as removing an alias while `gpg` stays, affects nothing.
- **Confirmation.** `-y`/`--yes`, anywhere among `add`'s or `rm`'s arguments, answers yes. Without it, a question asked when stdin isn't a terminal is an error that suggests `-y`, and nothing is changed.
- `source add <name> <git-url>` clones into `${BULKHEAD_SOURCES_DIR}/<name>`. The name follows `data_dir`'s rule, and `core` is reserved. A clone without `bin/`, without a valid manifest, or needing another version is deleted again; nothing else is ever deleted by `add`.
- `source rm <name>` refuses while links in the invoked bin dir still point into the source, while the clone has uncommitted changes, and while it has commits its upstream doesn't.

**`install.sh`** is standalone. It runs before the clone exists, so it has its own log helpers and can't source `lib/`.
- It checks for `bash`, `git` and `container` (without starting the service).
- It requires `container` to be at least `CONTAINER_MIN_VERSION` (1.5). It takes the first `X.Y[.Z]` in `container --version`'s output and compares only major and minor. It stops, printing the raw output, if the command fails or no version number is found. Only the installer checks the version; wrappers don't.
- It creates `~/.local/{share,bin}` and symlinks `bin/bulkhead` into `~/.local/bin`.
- It prints a `PATH` hint when `~/.local/bin` isn't on `PATH`.

Where the clone lives:
- **Piped** (`$0` isn't a file): the repository is cloned into `~/.local/share/bulkheads`.
  - If a clone of the same repository is already there, the installer runs `git pull --ff-only`.
  - If the directory is a clone of another repository, the installer warns and leaves it alone.
  - If the directory exists but isn't a git clone, the installer exits with an error.
- **Run from a checkout**: the checkout is used in place if it has `bin/bulkhead` and `.git` and its `origin` matches `REPO_URL` (SSH and HTTPS forms compare equal). Otherwise the installer refuses to run, which covers forks. The installed symlinks point into the checkout, so it mustn't be moved.

The repository and install directory are named `bulkheads`, while the project and command are `bulkhead`.

## Versioning and the public API

`BULKHEAD_VERSION` in `lib/core.sh` is the project's semver version, matched by a `vX.Y.Z` git tag. Bump the variable and tag the same commit. It is always a plain `X.Y.Z`: bulkhead never tags pre-releases or adds build metadata, and the source check exits if the version isn't plain (`tests/semver.test.sh` checks it).

- **MAJOR** when a source written for the old version could break: a public function or global is removed or renamed, or changes its arguments, return or exit behaviour, or reported values. Also a change to the preamble, the data layout (`~/bulkhead-data/<name>`), the `bulkhead/<name>` image naming or the `bulkhead-source` format.
- **MINOR** when something is added to the public API or the manager.
- **PATCH** for everything else, including changes to core wrappers.

The public API is what sources may use. It is documented in [`docs/api.md`](docs/api.md), which is the list: every function and global it names, its wrapper headers, and the `bulkhead-source` format.
- `tests/lint.test.sh` checks that the public functions in `lib/` and the function headings in `docs/api.md` are the same set, and that every documented global is set in `lib/`.
- A new public function or global goes in `docs/api.md` and bumps MINOR. A change to a documented behaviour updates its entry in the same commit.

Everything else in `lib/` is internal and may change in any release: every function starting with `_`, and every `lib/_*.sh` part.

`_bulkhead_version_satisfies <requirement>` is the semver check behind `requires`. What it accepts and rejects is in [`docs/api.md`](docs/api.md#the-bulkhead-source-manifest).
- There are deliberately no ranges or upper bounds. bulkhead promises compatibility within a major and breaks it at the next, so a minimum version is all a source can usefully state. Major 0 is rejected because bulkhead has no 0.x releases.
- An invalid requirement, or an invalid `BULKHEAD_VERSION`, is misuse and exits.
- The parts are compared as strings, by length and then text, through `_semver_parse`, `_semver_num_cmp` and `_semver_compare`. Shell arithmetic is never used, so no number can overflow.

## Sources

A source is a git repository of extra wrappers that shouldn't live in this repository. How users add one is in [`docs/sources.md`](docs/sources.md). It contains:

```
<source-repo>/
├── bulkhead-source   # required: requires=<major>[.<minor>[.<patch>]] of bulkhead it relies on
├── bin/<wrapper>     # wrappers only, with the standard two-line preamble
├── README.md         # its wrapper table
└── AGENTS.md         # points to $(bulkhead home)/AGENTS.md, plus per-wrapper facts
```

- Source wrappers follow every rule in this file. They add nothing to the preamble: the loader does the compatibility check.
- `bulkhead-source` (format in [`docs/api.md`](docs/api.md#the-bulkhead-source-manifest)) is read with `while read` by `_bulkhead_source_requires` and never sourced, because it comes from another repository. `examples/source` is a complete working source (manifest, `bin/tree`, README.md, AGENTS.md). Keep it in step with this file: its `requires` matches the current major, and its wrapper follows the current pattern.
- A source wrapper must not refer to `${BULKHEAD_HOME}/bin/…`, which is the core clone, and must use only the public API. It never calls a `_`-prefixed function: `grep -nE '(^|[^A-Za-z0-9_])_(container|image|registry|bulkhead|deps|args)_' bin/*` must print nothing.
- Wrapper names must be unique across core and sources in practice: images are `bulkhead/<name>` and data is `~/bulkhead-data/<invoked name>`, regardless of which repository a wrapper comes from.

## Runtime state

- **Stamps.** Build and base stamps are stored in `${BULKHEAD_SYSTEM_DIR}` as `.<slug>.<kind>`. The slug replaces `/` and `:` with `_`, and the kind is `built`, `checked` or `base-digest`. Values are `date +%s` epochs or digests.
  - Stamps are keyed on the built `bulkhead/<name>` image, never on the base, so two wrappers sharing a base keep separate throttles. An official-image wrapper builds no image, so its stamps are keyed on the official image (e.g. `.hashicorp_terraform_1.15.checked`).
  - Never read a timestamp back off the image. `container image inspect` has no `--format`, and its date encoding is unreliable ([apple/container#1533](https://github.com/apple/container/issues/1533)).
- **Deleting a stamp is safe.** Delete stamp files one by one, never `.bulkhead` as a whole: it also holds the source clones, which may hold work that exists nowhere else.
  - Deleting `checked` causes another Hub check.
  - Deleting `base-digest` makes the next check see a change and rebuild.
  - Deleting `built` makes the `age` policy rebuild, and turns off the script check until the next build.
- **Sources** are clones under `BULKHEAD_SOURCES_DIR` (`~/bulkhead-data/.bulkhead/sources/<name>`). The clone list is the source list; there is no other registry.
  - It sits inside `BULKHEAD_SYSTEM_DIR` so everything bulkhead owns is under `~/bulkhead-data`, and backing that folder up includes the sources. No wrapper mounts `BULKHEAD_DATA_DIR` or `.bulkhead` itself, so containers never see the clones; a wrapper must keep it that way.
- **Temporary files.** `BULKHEAD_SYSTEM_DIR` also holds `empty-context/` (the build context) and the temporary Dockerfiles `image_build` spools, next to `sources/`.

## Security model and known issues

- **Isolation.** Each container runs in its own lightweight VM with its own kernel. It sees only its mounts: the working directory, which is read-write by design, plus any `DATA_DIR`. Root inside a per-container VM is a narrower privilege than root in a Docker container, but this is **not** a hardened boundary for untrusted or autonomous code.
- **Builder resources.** The builder can be started larger with `container builder start --cpus 8 --memory 16g`; these flags haven't been checked against the installed version. `claude` resets the builder before every build, which throws away a custom-sized builder.
- **External volumes.** `container` keeps its state under `~/Library/Application Support`, and has known problems when that path, or a mounted directory, is on an external or non-APFS volume ([apple/container#1721](https://github.com/apple/container/issues/1721), [apple/container#1830](https://github.com/apple/container/issues/1830)). `BULKHEAD_DATA_DIR` is hard-coded to `${HOME}/bulkhead-data`, so there's no workaround short of keeping the home directory on the internal disk.

## Tests

`tests/run` (or `make test`) runs every `tests/*.test.sh`; `tests/run deps` runs only `tests/deps.test.sh`. Run it after changing `bin/bulkhead`, `lib/` or this file's checkable rules.
- Plain Bash with no framework. `tests/lib.sh` holds the assertions, and a sandbox that points `HOME` at a temporary directory, so no real data, sources or links are touched. Each `test_*` function runs in its own subshell with a fresh sandbox.
- **Tests never call `container`.** They cover the manager's linking and the lib's greppable rules, not a wrapper's run.
- `deps.test.sh` covers `add`/`rm` dependencies against the core `git-secret`/`gpg` and a generated fixture source, and the `_deps_*` functions on their own.
- `layout.test.sh` pins the on-disk layout: `~/bulkhead-data` and `~/bulkhead-data/.bulkhead/sources`, and that an existing install's source links can still be listed, added and removed. Existing installs depend on these paths, so it spells them out rather than reading `lib/core.sh`, and it's the only test file allowed to. Moving one on purpose means a migration and a MAJOR bump.
- `semver.test.sh` covers the `requires` check: the `_semver_*` helpers, `_bulkhead_version_satisfies` against a range of installed versions, manifest parsing (CRLF, spaces, invalid values), `bulkhead source add` accepting or refusing a source, and that `BULKHEAD_VERSION` itself is plain `X.Y.Z`.
- `lint.test.sh` turns this file's checkable rules into tests: syntax, the layering greps, the loader never loading a manager-only part, the `_` prefix and `# Internal:` lines, and `docs/api.md` matching the public functions.
- The tests need only Bash and Git, and never a terminal. Bash can't open one, so `_confirm`'s typed answers (`y`, `n`, empty) aren't tested. The prompts' lists and the link order are tested through `-y`, and the refusal without a terminal through `</dev/null`.

## Keeping documentation current

After any structural change (a new or renamed wrapper, a changed lifecycle step, a new convention), update the user docs and this file:

- **README.md** first. It's the user-facing entry point and stays short: a one-paragraph intro, requirements, install, usage, the wrapper table, isolation, one-line troubleshooting and uninstall. Anything longer goes in a user guide in `docs/`, with a one-line link from the README.
  - The user guides are `docs/sources.md` (adding sources), `docs/images.md` (when images are rebuilt) and `docs/gpg.md` (git-secret's keyrings). Explanations of general behaviour, such as how images stay fresh, don't name specific tools.
  - The wrapper table lists every committed wrapper with a one-line purpose and what it keeps. Add a row when a wrapper is committed, and remove it when the wrapper is. Don't list a wrapper that exists only in the working tree.
- **AGENTS.md** next. Rules, rationale, per-wrapper facts, upstream issue references and implementation details go here.
- **`docs/api.md`** whenever a public function, global, wrapper header or the `bulkhead-source` format changes. `make test` fails while it's out of step with `lib/`.
  - **`docs/sources.md`** too when the `bulkhead-source` format or the meaning of `requires` changes, since it explains both for users.
