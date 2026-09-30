# Example bulkhead source

A bulkhead source is a git repository of extra wrappers that `bulkhead` can add without
them being part of the bulkheads repository. Copy this folder to start one.

## Structure

```
<your-source>/
├── bulkhead-source   # manifest: the bulkhead version the wrappers rely on
├── bin/
│   └── tree          # one executable wrapper per tool, no file extension
├── README.md         # this file: what the source holds
└── AGENTS.md         # rules for AI agents working in the source
```

## Use

```bash
bulkhead source add example git@github.com:you/your-source.git
bulkhead add tree                 # or example/tree if the name is taken
tree -L 2
```

The functions a wrapper may use, and the headers and manifest keys bulkhead reads, are
listed in bulkhead's [`docs/api.md`](../../docs/api.md) (`$(bulkhead home)/docs/api.md`).

## Wrappers

| Wrapper | Runs | Keeps |
|---|---|---|
| `tree` | `tree` from Alpine, against the current directory | nothing |
