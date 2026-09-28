# AGENTS.md

Guidance for AI coding agents working in this repository. README.md is the user-facing documentation; this file holds the rules, the reasons behind them, and the implementation details.

## Overview

`docklet` is a set of Bash wrapper scripts in `bin/`. Each one runs a developer CLI tool in a disposable container using Apple's `container` CLI (Apple silicon, macOS 26+). **Docker is not used anywhere.** `container` is the only engine and there is no fallback. There is no build system, package manager or test suite, and each file in `bin/` is an independent executable.

- `bin/docklet`: the manager. It symlinks wrappers from the clone into `~/.local/bin`, and `docklet home` prints the clone root.
- `bin/<tool>`: the wrappers. They find the shared library through `docklet home`, so `docklet` must be on `PATH`. This is a hard requirement with no local fallback.
- `lib/common.sh`: a loader that sources five layered parts (see [The shared library](#the-shared-library)).
- `install.sh`: a standalone bootstrap installer.

**Possible rename (not acted on).** As of 2026-09-29, a rename from `docklet` to `sandlet` is under consideration. The project has moved from Docker to Apple's `container` CLI, so the name no longer fits: "dock" suggests Docker, which is no longer used. Nothing has been decided. Keep `docklet` everywhere (commands, `docklet/<name>` images, `DOCKLET_*` variables, `~/docklet-data`, repo paths) unless asked.

## Wrappers

| Wrapper | Image | Rebuild policy | `DATA_DIR` mount | Own `update` |
|---|---|---|---|---|
| `claude-code-cli` | built on `alpine:latest` | `base` | `/config` | yes |
| `kiro-cli` | built on `debian:stable` | `base` | `/opt/kiro/.kiro`, `/opt/kiro/.local/share/kiro-cli` | no |
| `terraform` | official `hashicorp/terraform:1.15` | none; tag resolved at runtime | none (`HOME=/tmp`) | no |
| `unrar` | built on `alpine:3.17.2` from a pinned source tarball | `missing` | none | no |
| `yt-dlp` | built on `debian:13.4-slim`, installing the latest release | `age`, weekly | none | yes |

Every wrapper also mounts the working directory: at `/work` for `claude-code-cli` and `kiro-cli`, and at `/data` for the others. Wrappers without a `DATA_DIR` keep nothing between runs.

`bin/claude-code-cli` is the reference for the build pattern and `bin/terraform` for the official-image pattern.

## The wrapper pattern

Preserve this structure when adding or editing a wrapper:

1. **Preamble.** Start with these two lines:
   ```sh
   DOCKLET_HOME="$(docklet home)" || { echo "docklet not found on PATH; install docklet first" >&2; exit 1; }
   . "${DOCKLET_HOME}/lib/common.sh"
   ```
   The `||` keeps it `set -e`-safe. Always source `lib/common.sh`, never a single part, so the whole API is available and the layout can change without touching `bin/`.

2. **Variables.** Set `IMAGE`. If the tool keeps state, also set `DATA_DIR="$(data_dir)"`. `data_dir` returns `${PERSISTENT_DATA_DIR}/<invoked name>` (from `basename "$0"`), so an alias symlink gets its own isolated state. Keep it based on the invoked name, never on the resolved path.

3. **Decide whether to build.** Use exactly one line, never a hand-rolled check:
   ```sh
   image_needs_build "${IMAGE}" missing              && build   # everything pinned
   image_needs_build "${IMAGE}" age  "${PERIOD}"     && build   # installs "latest" on a pinned base
   image_needs_build "${IMAGE}" base "${BASE_IMAGE}" && build   # base tag moves
   ```
   - Every policy implies `missing`: an absent image always builds.
   - `age` compares against the build stamp written by `image_build`.
   - `base` checks the base image's Docker Hub digest at most once per `STALENESS_PERIOD`. It rebuilds only when the digest changed, and removes the stale local base first so the build pulls the new one. An unreachable Hub is never treated as a change, and the check time is still recorded so an outage can't make every run call Docker Hub.
   - The function reports through `BUILD_REASON` (`missing`/`age`/`base`/`none`) and, under `base`, through `BASE_CHECK` (`skipped`/`unchanged`/`changed`/`unreachable`).
   - Misuse **exits** rather than returning, so a caller bug is never read as "no build needed". Misuse means no image, an unknown policy, or a non-numeric period.

4. **Build.** The wrapper's builder is named `build` and always builds; the decision belongs to `image_needs_build`. Never name it `image_build`: that would shadow the lib's builder and recurse forever.
   - Pipe the Dockerfile to `image_build "${IMAGE}" [flags]` as an inline heredoc. There are no Dockerfiles on disk.
   - `image_build` supplies what `container build` needs:
     - `-t`, since an untagged image gets a UUID name.
     - An empty build context, since nothing is `COPY`d from the host and `container` syncs the context into the builder VM.
     - The Dockerfile by path. `-f -` (stdin) only landed upstream on 2025-11-18 ([apple/container#827](https://github.com/apple/container/pull/827)), after the installed version, so the heredoc is spooled to a temporary file.
   - `image_build` also rejects an empty Dockerfile, checks afterwards that the tag exists, and writes the build stamp.
   - Under the `base` policy, `build` must end with `image_record_base "${IMAGE}" "${BASE_IMAGE}"`, which runs only after a successful build so a failed build never marks the base as adopted.

5. **Wrapper commands.** A wrapper that has its own command (today only `update`) parses its arguments with `args_parse`, never by hand:
   ```sh
   args_parse update "$@"
   container_require
   if [ "${ARGS_COMMAND}" = "update" ]; then
   	image_update "${IMAGE}" "the latest yt-dlp release" || exit 1
   	exit 0
   fi
   ```
   - The command counts only as a bare word *before* the first `--`.
   - The first `--` is consumed, and everything after it is forwarded verbatim, so `yt-dlp -- update` reaches yt-dlp itself.
   - Anything else is forwarded unchanged in `FORWARD_ARGS`.
   - The command is matched by exact string comparison, not as a pattern, and giving it twice is a usage error.
   - Neither `args_parse` nor `image_update` exits on the wrapper's behalf; the wrapper owns its exit status.
   - `image_update` returns 0 when the image is gone, including when there was nothing to remove. It returns 1, with a warning, when the image can't be removed, usually because another session still holds it.

6. **Run.**
   - `mkdir -p` each mount source first.
   - Then run `container run --rm` with the mounts, passing `"${FORWARD_ARGS[@]}"` (or `"$@"` when there's no `args_parse`) to the entrypoint.
   - Use `-it` for interactive tools. Tools that should also work in pipelines use `-i`, adding `-t` only when `[ -t 0 ]`.
   - **Never pass `--user`, and don't bake a non-root `USER` into an image.** `container` presents bind mounts as root-owned inside the guest and has no UID mapping yet ([apple/container#165](https://github.com/apple/container/issues/165)), so a non-root process couldn't write to its own mounts. Files written by root in the container still come back owned by the macOS user.

## Choosing an image

- **Prefer an official Docker Hub image** when the tool publishes one. Run it directly, with no Dockerfile, no `image_needs_build` and no `build`, since `container run` pulls it on first use.
- **Pin a `major.minor` tag** (e.g. `hashicorp/terraform:1.15`), never `:latest`. Moving to a new major means bumping the tag by hand.
- **Resolve the tag at runtime.** Call `registry_resolve_image "${IMAGE}"` after `container_require`, and run `"${RESOLVED_IMAGE}"` instead of `"${IMAGE}"`.
  - It checks Docker Hub at most once per `STALENESS_PERIOD`.
  - It adopts newer minors within the pinned major and never a newer major.
  - It is silent and reports only through `RESOLVED_IMAGE` and `IMAGE_MAJOR_AVAILABLE`. The wrapper uses `log_info` when the resolved tag differs from the pin, and `log_warn` when a newer major exists.
  - Network errors and non-numeric tags leave the pin unchanged.
- **Use the build pattern only when necessary**: when there's no official image, when the tool installs through npm, pip, gem or an install script, or when significant post-install setup is needed.
  - Name the image `docklet/<script-name>` so `IMAGE` matches the wrapper's filename.
  - Pick the base by what drifts: a moving base tag gets `base`; a pinned base that installs "latest" gets `age`; fully pinned gets `missing`.
- `container build` rejects Dockerfiles larger than 16 KiB on stdin. `image_build` passes the file by path, so it's not known whether the limit still applies. The current Dockerfiles are far below it either way.

## The shared library

`lib/common.sh` resolves its own directory with `cd -P`/`dirname`, as `bin/docklet` does (never `readlink -f`, which is GNU-only). It sources the parts in this order:

| Part | Holds | May use |
|---|---|---|
| `core.sh` | `PERSISTENT_DATA_DIR` (`~/docklet-data`), `DOCKLET_SYSTEM_DIR` (`…/.docklet`), `STALENESS_PERIOD` (1 day), `log_info`/`log_warn`/`log_error`, `data_dir` | nothing |
| `args.sh` | `args_parse` | core |
| `engine.sh` | `container_require`, `container_start_system`, `container_builder_reset`, `container_build_context` | core |
| `registry.sh` | `registry_digest_changed`, `registry_resolve_image` | core |
| `image.sh` | `image_exists`, `image_remove`, `image_build`, `image_update`, `image_needs_build`, `image_record_base`, `image_slug`, `image_stamp_path`, `image_stamp_stale` | core, engine, registry |

**Keep the layering intact and greppable:**
- `registry.sh` never calls `container`. Docker Hub is the registry `container` pulls from, not the Docker engine, which is why this code survived the removal of Docker. `grep -n '^[^#]*container ' lib/registry.sh` must print nothing.
- `core.sh` calls neither `container` nor `curl`.
- No part depends on a layer above it. That's why `image_build` lives in `image.sh`: it uses `image_exists` and writes stamps.
- A new helper goes in the lowest layer that can hold it. Needing a higher layer means the helper belongs higher up; it's not a reason to relax the rule. A new part must be added to the loader's `for` list.
- Every part has a `_DOCKLET_<PART>_SH` include guard and sources its own dependencies, so one layer can be loaded on its own. For example, `. lib/registry.sh` works with no `container` installed, for testing.
- Parts are source-only: they define functions and variables, never execute anything, and never `set -e`. Run-time setup such as `mkdir -p` goes inside functions.

## Conventions

- `set -e`, tabs, a `main` function invoked as `main "$@"`, and distinct units split into functions, each with a short comment above it.
- **Shared functions are named group first**, as `<group>_<verb>[_<object>]`: `container_require`, not `require_container`. The prefix names the owning file: `container_` → engine, `image_`, `registry_`, `args_`, `log_` → core. `data_dir` is a plain accessor. Wrapper-local functions (`main`, `build`, `resolve_default_opts`) take no prefix.
- **Declare working variables with a bare `local a b c` line**, separate from any assignment. The lib reports through globals, so an undeclared variable can clobber a caller's. `local x="$(cmd)"` also masks `cmd`'s exit status, which the offline paths depend on.
- macOS on Apple silicon only: Bash and BSD userland, with no GNU-only flags and no Linux code paths.
- Shared helpers and paths live in `lib/`; never redefine them in a wrapper.
- **All image operations go through `image_*`.** `container image inspect` and `container image rm` appear only in `image_exists` and `image_remove`. The lib owns `image_build` and `image_update`, and a wrapper must not define either.
- **Never call `docker`.**
  - `container_require` gates every run. It starts the service itself through `container_start_system`, and only a missing CLI or a service that won't come up is fatal.
  - When stdin isn't a terminal, the start passes `--enable-kernel-install`, because the first-start kernel prompt can't be answered there.
  - The build cache lives in the builder container, and there is no `builder prune`. `container_builder_reset` (`builder delete --force`) clears the cache.
- `container` command groups are singular (`container image ls`). An unknown subcommand reports a *service* error, so check the spelling before restarting anything.

## Manager and installer

**`bin/docklet`** has these commands: `help`, `home`, `update` (a plain `git pull` of the scripts, which leaves images alone), `add <name> [<alias>]` and `rm <name|alias>`. There is no `refresh`; a wrapper's own `update` forces a rebuild.
- `add` links into the directory `docklet` was invoked from (normally `~/.local/bin`). It refuses to overwrite anything except an identical existing link.
- `rm` removes only a symlink that points into the clone's `bin/`, and never touches data or images.

**`install.sh`** is standalone. It runs before the clone exists, so it has its own log helpers and can't source `lib/`.
- It checks for `bash`, `git` and `container` (without starting the service).
- It creates `~/.local/{share,bin}` and symlinks `bin/docklet` into `~/.local/bin`.
- It prints a `PATH` hint when `~/.local/bin` isn't on `PATH`.

Where the clone lives:
- **Piped** (`$0` isn't a file): the repository is cloned into `~/.local/share/docklets`.
  - If a clone of the same repository is already there, the installer runs `git pull --ff-only`.
  - If the directory is a clone of another repository, the installer warns and leaves it alone.
  - If the directory exists but isn't a git clone, the installer exits with an error.
- **Run from a checkout**: the checkout is used in place if it has `bin/docklet` and `.git` and its `origin` matches `REPO_URL` (SSH and HTTPS forms compare equal). Otherwise the installer refuses to run, which covers forks. The installed symlinks point into the checkout, so it mustn't be moved.

The repository and install directory are named `docklets`, while the project and command are `docklet`.

## Runtime state

- **Stamps.** Build and base stamps are stored in `${DOCKLET_SYSTEM_DIR}` as `.<image_slug>.<kind>`. The slug replaces `/` and `:` with `_`, and the kind is `built`, `checked` or `base-digest`. Values are `date +%s` epochs or digests.
  - Stamps are keyed on the *docklet* image, never on the base, so two wrappers sharing a base keep separate throttles.
  - Never read a timestamp back off the image. `container image inspect` has no `--format`, and its date encoding is unreliable ([apple/container#1533](https://github.com/apple/container/issues/1533)).
- **Official-image cache.** `registry_resolve_image` writes `.<repo slug>-last-checked` and `.<repo slug>-resolved` directly in `${PERSISTENT_DATA_DIR}` (e.g. `.hashicorp_terraform-resolved`), not in `.docklet/`.
- **Deleting state is safe.**
  - Deleting `checked` causes another Hub check.
  - Deleting `base-digest` makes the next check see a change and rebuild.
  - Deleting `built` makes the `age` policy rebuild.
- **Temporary files.** `DOCKLET_SYSTEM_DIR` also holds `empty-context/` (the build context) and the temporary Dockerfiles `image_build` spools.

## Security model and known issues

- **Isolation.** Each container runs in its own lightweight VM with its own kernel. It sees only its mounts: the working directory, which is read-write by design, plus any `DATA_DIR`. Root inside a per-container VM is a narrower privilege than root in a Docker container, but this is **not** a hardened boundary for untrusted or autonomous code.
- **Builder resources.** The builder can be started larger with `container builder start --cpus 8 --memory 16g`; these flags haven't been checked against the installed version. `claude-code-cli` resets the builder before every build, which throws away a custom-sized builder.
- **External volumes.** `container` keeps its state under `~/Library/Application Support`, and has known problems when that path, or a mounted directory, is on an external or non-APFS volume ([apple/container#1721](https://github.com/apple/container/issues/1721), [apple/container#1830](https://github.com/apple/container/issues/1830)). `PERSISTENT_DATA_DIR` is hard-coded to `${HOME}/docklet-data`, so there's no workaround short of keeping the home directory on the internal disk.

## Keeping documentation current

After any structural change (a new or renamed wrapper, a changed lifecycle step, a new convention), update both files:

- **README.md** first. It's the user-facing source of truth and stays short: requirements, install, usage, the wrapper table and one-line troubleshooting. Explanations of general behaviour, such as how images stay fresh, don't name specific tools.
- **AGENTS.md** next. Rules, rationale, per-wrapper facts, upstream issue references and implementation details go here, including the [Wrappers](#wrappers) table.
