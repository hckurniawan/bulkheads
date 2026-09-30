# AGENTS.md

This repository is a bulkhead source: wrappers only, run by the bulkhead core.

Read `$(bulkhead home)/AGENTS.md` first. Its wrapper pattern, image rules and
conventions apply here unchanged, and its "Sources" and "Versioning and the public
API" sections define what a source may rely on. Don't copy those rules into this
file; record only what is specific to this repository.

## Rules for this source

- Wrappers use only the core's public API, documented in `$(bulkhead home)/docs/api.md`,
  and never refer to `${BULKHEAD_HOME}/bin/…`. Anything starting with `_` is internal.
- A wrapper that needs another one declares it with `# bulkhead-needs: <name>` (see
  docs/api.md). A bare name means a wrapper in this source; use `core/<name>` for a core
  wrapper.
- Using something added in a newer bulkhead minor, or relying on a fix in a newer
  patch, means raising `requires` in `bulkhead-source` in the same commit.
- Wrapper names must not clash with core wrappers or other sources you use.
- Add a row to README.md's wrapper table for every committed wrapper.

## Wrappers

- **`tree`**: built from a pinned Alpine base (`missing` policy). Mounts the working
  directory at `/data`; keeps no data.
