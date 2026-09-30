# git-secret and gpg keyrings

`git-secret` runs with the same GnuPG as `gpg`, and uses a `gpg` keyring instead of keeping its own.

**Without a `gpg` alias, there's nothing to set up.** `git-secret` uses the keys you manage with `gpg`, in `~/bulkhead-data/gpg/`. That's why `bulkhead add git-secret` also offers to add `gpg`.

**With a `gpg` alias**, which has its own keyring, tell each repository that should use it. Name the alias in that repository's git config:

```bash
bulkhead add gpg gpg-work                  # a separate keyring: ~/bulkhead-data/gpg-work/
gpg-work --import work-key.asc
git config bulkhead.gpgKeyring gpg-work    # in the repository, once
git secret reveal                          # now uses the gpg-work keyring
```

The alias's keyring is created the first time you run the alias. Until then, `git-secret` in a repository that names it stops with an error rather than use an empty keyring, so run the alias (e.g. the `--import` above) first.

Add `--global` to make the alias's keyring the default for every repository; a repository's own setting still wins.

Either way, run `git-secret` (or `git secret`) from the repository's root folder, since only the current folder is mounted.
