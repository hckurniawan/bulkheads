# Adding your own wrappers

Wrappers you don't want in this repository can live in a separate git repository, a *source*:

```bash
bulkhead source add personal git@github.com:you/my-wrappers.git
bulkhead source ls                         # sources, compatibility and remotes
bulkhead add mytool                        # or personal/mytool if the name is taken
bulkhead source rm personal                # after removing its wrappers with bulkhead rm
```

`bulkhead update` pulls every source along with bulkhead itself. Sources are cloned in `~/bulkhead-data/.bulkhead/sources/`, so they're deleted along with `~/bulkhead-data`; push any changes you made in them first.

## What a source contains

A source needs a `bin/` folder of wrappers and a `bulkhead-source` file stating the bulkhead version it relies on, e.g. `requires=2.0` (or `requires=2` for any 2.x, or `requires=2.0.3` to need a patch release). A wrapper from a source that needs a different bulkhead version refuses to run and says what to update.

[`examples/source`](../examples/source) is a complete source to copy: manifest, a wrapper, README.md and AGENTS.md.

## Writing wrappers

[`api.md`](api.md) lists the functions and globals a wrapper may use, the `# bulkhead-needs:` header, and the full `bulkhead-source` format.
