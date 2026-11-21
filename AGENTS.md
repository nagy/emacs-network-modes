# AGENTS.md — emacs-network-modes

## Purpose

`network-modes` gives Emacs read-only major modes that inspect network
values: IPv4 and IPv6 addresses, CIDR prefixes, MAC addresses,
autonomous system numbers, domain names and AF_VSOCK addresses.  Emacs
Lisp on Emacs 31.1, AGPL-3.0-or-later.  The single required dependency
is `magit-section`.  A buffer reads pinned offline databases, and
`net-rdap` is the only code path that touches the network.

## Layout

- `network-modes.el`: entry library.  Loads the base mode and the six
  modes and provides the feature `network-modes`.
- `net-mode.el`: base mode and shared layer.  Kind registry,
  dispatcher, report renderer, point keeping, text links, bookmarks,
  RDAP, JSON view, CSV and packed table readers.
- `net-ip.el`, `net-cidr.el`, `net-mac.el`, `net-asn.el`,
  `net-domain.el`, `net-vsock.el`: one kind each, split into parser,
  sniffer, report builder and mode.
- `net-geo.el`: country lookup over the range tables.
- `ol-net.el`, `embark-net.el`, `net-xref.el`, `net-evil.el`: opt-in
  integration libraries.  No mode requires them.
- `test/`: ERT suite, one `*-test.el` per source unit, shared fixtures
  in `network-modes-test-helper.el`.
- `tools/pack-network-data.el`: build-time packer for the four range
  tables.
- `flake.nix`: derivation, data inputs, checks, devShell, treefmt.
- `README.org`: user documentation, the key tables and the database
  list.  Read it before you change user-visible behaviour.

## Build and test

- `nix flake check`: the gate.  Runs the package build, the ERT suite
  twice, package-lint, checkdoc, the packed-table check and treefmt.
- `nix build`: the package derivation.
- `nix develop`: dev shell with the wrapped Emacs, package-lint,
  embark and evil.
- `nix fmt`: nixfmt through treefmt.  Do not run nixfmt directly.

## Architecture

One value string reaches a report plist.  The report alone draws both
the buffer and the JSON view.

### Kind registry

A mode file calls `net-register-kind` at load time with `:open`,
`:report`, `:sniff` and `:priority`.  `net-sniff` loads a kind library
on demand and tries the sniffers from the highest priority to the
lowest, so a narrow syntax claims a token before a broad one.  A new
kind takes a priority that matches how narrow its syntax is.

### Reports

Every mode owns a pure `net-KIND-report` that returns one plist with
`:summary`, `:sections` and, when the value has one, its RDAP
identity.  `net--render-report` draws that plist.  `net--render-item`
owns the item shapes and `net--json-value` owns the JSON encoding.
Report keys spell the JSON keys, and RDAP names (RFC 9083) win where
the concept exists.  A display label never reaches the JSON.

### Rendering

A render erases the buffer and inserts the tree again, so a refresh
redraws only when the report changed.  A section keeps point by its
identity, not by its line number, and `net--field-value` keeps the
value of a row unique among its siblings.  The section comments of
`net-mode.el` give the rest.

### Data access

Each reader caches on a key of (file, modification time, size), so an
edited database file invalidates the cache without a restart.  A
packed range table carries a header that the reader checks, and the
raw CSV or gzip form stays readable when a file lacks the magic bytes.

## Rules

- Run `nix flake check` before you commit.  A byte-compile warning
  breaks the build.
- A new field belongs to the report builder, never to the renderer.
  Add its key, its item and its value in `net-KIND-report`.
- Renderers use only the helpers of `net-mode.el`.  Do not insert raw
  text, and do not add a field outside the report.
- Every row renderer opens a section whose value is its label, through
  `net--field-value`.  Keep a count, a size and a timestamp out of a
  section value, because the fold and the point record would die on
  every render.
- Markers stay inhibited in every inspect buffer.  Do not use
  `magit-insert-section-body`, which signals on a marker free `end`.
- A Boolean in a report holds `t` or `:json-false`.  A nil value means
  unknown and encodes as `null`.
- `network-modes.el` is the package door.  The `pname` in `flake.nix`
  matches it, and no other file requires it.
- Keep the four integration libraries out of the entry library and out
  of `Package-Requires`.
- A derived kind registers its report builder as `:report`, because
  `net-refresh` compares it.  Keep that builder free of new side
  effects.
- A new command in `net-mode-map` belongs in `net-evil-keys`, and in
  `net-evil-visual-keys` when visual state needs it.
- Never vendor a database.  Add a flake input, a symlink in the data
  derivation and a `defcustom` that defaults to
  `(net-data-file "NAME")`.
- An invalid value signals `user-error` from its inspect command and
  never from a renderer.  An unknown value renders `unknown`.
- Bump `net--binary-version` with `tools/pack-network-data.el` when
  the packed layout changes.

## Conventions

- Prefix: `net-KIND-` for the public symbols of a kind, `net--` for
  internal helpers, `net-` for `defcustom`.
- Declare a pure helper `(declare (pure t) (side-effect-free t))`.  A
  function that runs a regexp keeps no declaration, because
  `string-match` clobbers the match data.  A reader that fills a cache
  keeps none either.
- Keep lines under 80 columns, docstrings included.
- Every `define-derived-mode` form carries `:interactive nil`.
- A row that names a database file carries the text and the path in
  two members, and the text comes from `net-data-description`, so a
  store copy reads as a pinned copy.
- Commit subject: one imperative sentence, optionally with a
  `scope:` prefix.
- Put a new decision next to the code that enforces it, in the
  `;;; Commentary:` or in the docstring of that function.  This file
  holds only what spans several files.

## Testing

Run one suite by hand when you add a fixture:

```sh
emacs -Q --batch -L . -L test -L "$MAGIT_SECTION_DIR" -L "$EVIL_DIR" \
  $(printf -- "-l %s " test/*-test.el) \
  -f ert-run-tests-batch-and-exit
```

- One `net-KIND-test.el` per source unit, and `ert-deftest` names read
  `net-KIND-test-BEHAVIOR`.
- Shared fixtures use the `net-test--` prefix and live in
  `test/network-modes-test-helper.el`.  A new test file needs no flake
  edit, because the check globs `test/*-test.el`.
- Build every database fixture in a temporary file.  A test never
  reads a store path.
- Force a real render with `(net-refresh t)`.  A plain `net-refresh`
  keeps the old tree when the report did not change.
- A behaviour change ships a test.  The suite runs without the JSON
  tree-sitter grammar and with it, so both parents of `net-json-mode`
  stay covered.

## Dependencies

| dependency | required? | why |
|---|---|---|
| Emacs | required | the floor in `Package-Requires` |
| `magit-section` | required | mode, section tree, folds, motion |
| `evil` | optional | `net-evil.el` and its ERT suite |
| `embark` | optional | `embark-net.el` |
| `package-lint` | optional | the lint check |

Optional libraries never reach `Package-Requires`.  The build Emacs
carries `magit-section` and evil, so the build and the check phases
resolve both without an `EMACSLOADPATH` export.

## Open work

- See "Ideas not implemented" in `README.org`.  Delete an item there
  when it lands.
