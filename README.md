# bulkhead

A personal collection of Bash wrappers that run developer CLI tools in disposable containers on your Mac, using [Apple's `container` CLI](https://apple.github.io/container/documentation/). Each tool runs in its own lightweight VM, sees only the directory you run it from, and keeps its data in one folder, `~/bulkhead-data/<name>/`, that you can back up or copy to another Mac. Nothing gets installed on the Mac itself.

It's built around how I work rather than as a general-purpose tool. Add the wrappers you want and skip the rest.

## Requirements

- A Mac with Apple silicon, running macOS 26 or later
- Apple's [`container`](https://github.com/apple/container/releases) CLI, version 1.5 or later
- Bash and Git

## Install

```bash
curl -LsSf https://raw.githubusercontent.com/hckurniawan/bulkheads/main/install.sh | bash
```

Or clone the repository and run `make install` (or `./install.sh`) in it. The clone is then used where it is, so keep it there.

The installer puts the `bulkhead` manager in `~/.local/bin`. If `~/.local/bin` isn't on your `PATH` yet, it prints the line to add to your shell profile.

## Usage

```bash
bulkhead help                              # list commands and available wrappers
bulkhead add claude                        # add a wrapper to ~/.local/bin
bulkhead add claude claude-work            # add it under an alias, with separate data
bulkhead rm claude-work                    # remove a wrapper (its data is kept)
bulkhead update                            # pull the latest wrapper scripts (and every source)
bulkhead version                           # print the bulkhead version
```

Then run a wrapper by name from any directory, e.g. `claude [args...]`. An alias gets its own data folder, so you can keep, say, a work and a personal account side by side. `add` offers to add the wrappers a wrapper needs, and `rm` the ones that need it; `-y` answers yes.

Images refresh themselves when needed, and `<wrapper> update` forces it. See [docs/images.md](docs/images.md).

To add wrappers of your own from a separate git repository, see [docs/sources.md](docs/sources.md).

## Wrappers

More wrappers will be added over time.

| Wrapper | Purpose | Keeps data |
|---|---|---|
| `claude` | Anthropic's Claude Code CLI, the AI coding assistant. | Settings and history |
| `git-secret` | [git-secret](https://sobolevn.me/git-secret/): encrypts secret files inside a git repository with GPG. | Uses a `gpg` keyring ([docs/gpg.md](docs/gpg.md)) |
| `gpg` | [GnuPG](https://gnupg.org/): encrypts, decrypts and signs files, and manages keys. | Keyring |
| `terraform` | HashiCorp Terraform, from the official image. | Nothing |
| `unrar` | RARLAB's UnRAR: lists, tests and extracts RAR archives. | Nothing |
| `yq` | [yq](https://mikefarah.gitbook.io/yq/): reads, queries and converts YAML, JSON and XML, from the official image. | Nothing |

## Data and isolation

Each container gets only the directory you run it from (read-write) and, for tools that keep data, its own folder in `~/bulkhead-data/<name>/`. Everything else is thrown away when the container exits. Each container runs in its own lightweight VM, but this isn't a hardened sandbox for untrusted code.

## Troubleshooting

- **The container service won't start.** Wrappers start it for you. If that fails, run `container system start` to see why.
- **A build fails.** Reset the builder with `container builder delete --force`. The next build recreates it.
- **Your home directory is on an external volume.** `container` has known problems there. Keep your home directory on the internal disk.

## Uninstall

```bash
bulkhead rm <name>                    # for each wrapper you added
rm ~/.local/bin/bulkhead
rm -rf ~/.local/share/bulkheads       # or wherever you cloned it
```

`~/bulkhead-data` and the `bulkhead/*` images (`container image ls`) are left for you to delete. Deleting `~/bulkhead-data` also deletes any sources you added; push any changes you made in them first.
