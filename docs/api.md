# bulkhead public API

This page is for people writing wrappers, in a bulkhead source or in this repository. It lists every function and global a wrapper may use, what each one takes, and what it does when something goes wrong.

## Stability

- The public API is everything on this page. It follows the semver rules in AGENTS.md ("Versioning and the public API"):
  - A breaking change bumps MAJOR.
  - An addition bumps MINOR.
- Anything whose name starts with `_` is internal and may change in any release. That covers both functions (e.g. `_image_exists`) and lib parts (e.g. `lib/_deps.sh`). Wrappers must not call or source them.
- Everything here becomes available through the two-line preamble every wrapper starts with:
  ```sh
  BULKHEAD_HOME="$(bulkhead home)" || { echo "bulkhead not found on PATH; install bulkhead first" >&2; exit 1; }
  . "${BULKHEAD_HOME}/lib/common.sh"
  ```

**Returns** and **exits** below mean different things:
- A function that *returns* non-zero leaves the decision to the wrapper.
- A function that *exits* stops the wrapper. Functions exit only on misuse (a caller bug) or on an unrecoverable condition. They never exit for "nothing to do".

## Functions

### core

#### `log_info`
#### `log_warn`
#### `log_error`
```sh
log_info <message…>
```
- Prints one line to **stdout** with a coloured `[INFO]`, `[WARN]` or `[ERROR]` prefix. The arguments are joined with spaces.
- Add `>&2` when the line shouldn't mix with output the tool's caller may redirect.
- Always returns 0.

#### `data_dir`
```sh
DATA_DIR="$(data_dir)"            # ~/bulkhead-data/<invoked name>
DATA_DIR="$(data_dir <name>)"     # ~/bulkhead-data/<name>
```
- **Arguments.** With no argument, the name is `basename "$0"`, the name the wrapper was invoked as. An alias symlink therefore gets its own folder.
  - Pass a name only to use another wrapper's data. `bin/gpg` does this for git-secret's keyring.
- **Prints** `${BULKHEAD_DATA_DIR}/<name>` with no trailing newline. It doesn't create the folder; `mkdir -p` it before mounting.
- **Returns 1** with an error on stderr when the name is empty, starts with a dot or contains `/`. Under `set -e`, the assignment then exits the wrapper.

### args

#### `args_parse`
```sh
args_parse update "$@"
```
- **Arguments.** The first argument is the wrapper's one command of its own; the rest are the wrapper's arguments.
- **Sets**:
  - `ARGS_COMMAND`: the command, or empty when it wasn't given.
  - `FORWARD_ARGS`: an array of everything else, in order, to pass to the container.
- **Rules**:
  - The command counts only as an exact bare word *before* the first `--`.
  - The first `--` is consumed, and everything after it is forwarded verbatim, so `tool -- update` sends `update` to the tool.
  - Any other argument is forwarded unchanged.
- **Exits 1** when no command name is given, or when the command appears twice before `--`.
- It never runs the command; the wrapper acts on `ARGS_COMMAND`.

### engine

#### `container_require`
```sh
container_require
```
- Makes sure Apple's `container` CLI is installed and its system service is running, and starts the service if it isn't.
- When stdin isn't a terminal, the start passes `--enable-kernel-install`, because the first-start kernel prompt can't be answered there.
- **Exits 1** when the CLI is missing, or when the service won't start or doesn't respond after starting.
- Call it before any image or container operation.

#### `container_builder_reset`
```sh
container_builder_reset
```
- Deletes the builder container, which holds the build cache. The next build recreates it.
- Never fails.
- Any custom size the builder was started with is lost.

### image

#### `image_needs_build`
```sh
image_needs_build "${IMAGE}" missing              && build   # everything pinned
image_needs_build "${IMAGE}" age  "${PERIOD}"     && build   # installs "latest" on a pinned base
image_needs_build "${IMAGE}" base "${BASE_IMAGE}" && build   # base tag moves
image_needs_build "${IMAGE}" base "${IMAGE}"      && pull    # official image, tracked by digest
```
- **Returns 0** when the image must be built or pulled, and non-zero otherwise.
- **Every policy**:
  - An absent image always needs a build.
  - So does a built image whose wrapper script (`$0`, following symlinks) changed after its last `image_build`.
- **`age <seconds>`**: also rebuilds when the last `image_build` is older than the period.
- **`base <base-image>`**: asks Docker Hub for the base's digest, at most once per `STALENESS_PERIOD`.
  - When the digest has moved, it removes the stale local base so the build pulls the new one.
  - An unreachable Hub is never treated as a change.
- **Sets**:
  - `BUILD_REASON`: `missing`, `age`, `base`, `script` or `none`.
  - `BASE_CHECK`: `skipped`, `unchanged`, `changed` or `unreachable` under `base`, and empty otherwise.
- **Logs** what it checked and decided.
- **Exits 1** on misuse: no image, no or unknown policy, a non-numeric `age` period, or `base` without a base image.

#### `image_build`
```sh
image_build "${IMAGE}" [container build flags…] <<-EOF
	FROM alpine:3.24.2
	RUN apk add --no-cache tree
EOF
```
- Builds `<tag>` from the Dockerfile on stdin, using an empty build context. Nothing can be `COPY`d from the host.
- Extra arguments go to `container build`, e.g. `--no-cache`.
- On success, writes the build stamp that the `age` policy and the script check read.
- **Exits 1** when no tag is given.
- **Returns non-zero** in these cases:
  - The Dockerfile is empty.
  - The temporary Dockerfile can't be created.
  - `container build` fails; its status is returned.
  - The tag doesn't exist after a successful build.
- Name the wrapper's own builder `build`. A function named `image_build` would shadow this one.

#### `image_update`
```sh
image_update "${IMAGE}" "the latest Claude Code" || exit 1
```
- Removes the local image so that the next run builds or pulls a fresh one. This is the shared implementation of a wrapper's `update` command.
- The optional second argument only shapes the message.
- **Returns 0** when the image is gone, including when it was never there.
- **Returns 1**, with a warning, when the image exists but can't be removed, usually because another session is still using it.
- **Exits 1** when no image is given.

#### `image_record_base`
```sh
image_record_base "${IMAGE}" "${BASE_IMAGE}"
```
- Records the base digest the image was just built against, giving the next `base` check something to compare with.
- Call it as the last step of `build` under the `base` policy, and only after a successful build.
- For an official image, use the image as its own base: `image_record_base "${IMAGE}" "${IMAGE}"`.
- It reuses the digest `image_needs_build` fetched, and fetches one itself otherwise. When the fetch fails, it records nothing and returns 0, so the next run checks again.
- **Exits 1** when either argument is missing.

## Globals

| Global | Set by | Meaning |
|---|---|---|
| `ARGS_COMMAND` | `args_parse` | The wrapper command given, or empty |
| `FORWARD_ARGS` | `args_parse` | Array of the arguments to pass to the container |
| `BUILD_REASON` | `image_needs_build` | `missing`, `age`, `base`, `script` or `none` |
| `BASE_CHECK` | `image_needs_build` | `skipped`, `unchanged`, `changed`, `unreachable`, or empty outside `base` |
| `BULKHEAD_DATA_DIR` | the lib, on load | `${HOME}/bulkhead-data`, the root of every wrapper's data folder |
| `STALENESS_PERIOD` | the lib, on load | Seconds between Docker Hub checks under `base` (one day) |
| `BULKHEAD_VERSION` | the lib, on load | The installed bulkhead's semver version |

## Wrapper headers

`bulkhead` reads these comment lines from the leading comment block of a wrapper. It never runs the wrapper to read them.

#### `# bulkhead-needs: <name> [<name>…]`
```sh
# bulkhead-needs: gpg
```
- Declares the wrappers this one needs.
- `bulkhead add` offers to add any that aren't linked yet, and links them first.
- `bulkhead rm` offers to remove the wrappers that would be left with a need unmet.
- Any link to the needed wrapper satisfies the need, including an alias.
- Name resolution:
  - A bare name means a wrapper in the same repository: the core `bin/` for a core wrapper, the source's `bin/` for a source wrapper.
  - `core/<name>` and `<source>/<name>` reach another repository.
- If a need doesn't resolve, `bulkhead add` stops and links nothing.

## The `bulkhead-source` manifest

A source keeps this file at its repository root. It is `key=value` lines, parsed and never run. Comments, blank lines and unknown keys are ignored.

| Key | Meaning |
|---|---|
| `requires` | The bulkhead version the wrappers rely on, as `major`, `major.minor` or `major.minor.patch`, with missing parts counting as 0. A wrapper runs, and can be added, only when the installed bulkhead has the **same major** and is **at least this version**. See below. |

How `requires` is checked:

| `requires=` | Accepts |
|---|---|
| `2` | any 2.x.y |
| `2.1` | 2.1.0 and later, before 3.0.0 |
| `2.1.3` | 2.1.3 and later, before 3.0.0 |

- Each part is `0` or a number without leading zeros.
- These are rejected, and a manifest that uses one counts as invalid:
  - pre-releases (`2.1.0-rc.1`);
  - build metadata (`+…`);
  - ranges and operators (`^2`, `>=2`, `~2.1`);
  - major `0`.
- Whitespace around the value, including the CR of a CRLF line ending, is ignored.

[`examples/source`](../examples/source) is a complete working source.
