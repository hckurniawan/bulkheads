# docklet

A personal collection of Bash shortcuts that run developer CLI tools inside disposable containers, using [Apple's `container` CLI](https://apple.github.io/container/documentation/). The tools themselves never have to be installed on your Mac.

It's built around how I work rather than as a general-purpose tool. Add the shortcuts you want and skip the rest.

## Why

- **Isolation.** Each tool runs in its own lightweight VM and sees only the directory you run it from, plus its own data folder. It can't read or change the rest of your home directory, and nothing gets installed on your Mac.
- **Data portability.** Everything a tool keeps (config, credentials, history) lives in one place, `~/docklet-data/<name>/`. Back it up, or copy it to another Mac, and the tool picks up where it left off.
- **Separate settings for the same tool.** Add a wrapper under an alias and it gets its own data folder, so you can keep, say, a work and a personal Claude Code account side by side:

  ```bash
  docklet add claude-code-cli claude-work       # ~/docklet-data/claude-work/
  docklet add claude-code-cli claude-personal   # ~/docklet-data/claude-personal/
  ```

## Requirements

- A Mac with Apple silicon, running macOS 26 or later
- Apple's [`container`](https://github.com/apple/container/releases) CLI
- Bash and Git

## Install

```bash
curl -LsSf https://raw.githubusercontent.com/hckurniawan/docklets/main/install.sh | bash
```

Or clone the repository and run `./docklets/install.sh`. The clone is then used where it is, so keep it there.

The installer puts the `docklet` manager in `~/.local/bin`. If `~/.local/bin` isn't on your `PATH` yet, it prints the line to add to your shell profile.

## Usage

```bash
docklet help                              # list commands and available wrappers
docklet add claude-code-cli               # add a wrapper to ~/.local/bin
docklet add claude-code-cli claude-work   # add it under an alias, with separate data
docklet rm claude-work                    # remove a wrapper (its data is kept)
docklet update                            # pull the latest wrapper scripts
```

After adding a wrapper, run it by name from any directory, e.g. `claude-code-cli [args...]`.

Some wrappers accept `update`, which rebuilds their image with the tool's latest release on the next run. To pass the word `update` to the tool itself instead, put it after `--`:

```bash
claude-work update      # rebuild the image
claude-work -- update   # run yt-dlp's own update
```

## Data and isolation

Each container gets only the directory you run it from (read-write) and, for tools that keep data, its own folder in `~/docklet-data/<name>/`. Everything else is thrown away when the container exits. Each container runs in its own lightweight VM, but this isn't a hardened sandbox for untrusted code.

## Troubleshooting

- **The container service won't start.** Wrappers start it for you. If that fails, run `container system start` to see why.
- **A build fails.** Reset the builder with `container builder delete --force`. The next build recreates it.
- **Your home directory is on an external volume.** `container` has known problems there. Keep your home directory on the internal disk.

## Uninstall

```bash
docklet rm <name>                    # for each wrapper you added
rm ~/.local/bin/docklet
rm -rf ~/.local/share/docklets       # or wherever you cloned it
```

`~/docklet-data` and the `docklet/*` images (`container image ls`) are left for you to delete.
