# AGENTS.md — emacs-network-modes

## Overview

A set of read-only Emacs major modes that inspect network addresses:
IPv4/IPv6 addresses, CIDR prefixes, MAC addresses, autonomous system
numbers, domain names and AF_VSOCK addresses.

Every mode derives from `net-mode`, which derives from `special-mode`.
The shared layer supplies one buffer per inspected value, a header line
with a classification, copyable field buttons, cross-mode address
buttons, bookmarks, the `net-inspect` dispatcher and the explicit
`net-rdap` command.  RDAP is the only code path that touches the
network, and it runs only when invoked.

## Files

| File                | Purpose                                                                 |
| ------------------- | ----------------------------------------------------------------------- |
| `network-modes.el`  | Entry library and package namesake: requires the base mode and all six modes, then provides the feature `network-modes`. `(use-package network-modes ...)` and `:ensure t` load and resolve through it. |
| `net-mode.el`       | Base mode, kind registry, dispatcher, renderer, bookmarks, RDAP         |
| `net-geo.el`        | Country lookup from packed range tables or PDDL CSVs                    |
| `net-ip.el`         | IP parsing/formatting, blocks, registry reader, origin AS, IP mode      |
| `net-cidr.el`       | Prefix arithmetic, CIDR mode                                            |
| `net-mac.el`        | MAC/EUI-64 parsing, bit flags, IEEE and manuf vendor lookup             |
| `net-asn.el`        | AS parsing, IANA registry, ipverse metadata, IP to AS ranges, ASN mode  |
| `net-domain.el`     | Domain parsing, Punycode encoder, PSL lookup, domain mode               |
| `net-vsock.el`      | AF_VSOCK parsing, `sockaddr_vm` layout, service names, vsock mode       |
| `ol-net.el`         | Opt-in Org link types (`net-*:` and `net:`)                             |
| `embark-net.el`     | Opt-in Embark target and actions (`embark-net-mode`)                    |
| `net-xref.el`       | Opt-in xref backend                                                     |
| `net-evil.el`       | Opt-in evil bindings (`net-evil-mode`)                                  |
| `net-tests.el`      | ERT suite (86 tests)                                                    |
| `net-evil-tests.el` | ERT suite for the evil bindings (8 tests)                               |
| `flake.nix`         | Database inputs and derivation, `melpaBuild`, outputs and checks        |
| `tools/pack-network-data.el` | Packs the range databases into fixed-width tables              |
| `README.org`        | User documentation                                                      |
| `LICENSE`           | AGPL-3.0-or-later                                                       |

## Dependencies

Emacs 31.1 or newer.  All Elisp dependencies are built in: `bookmark`,
`button`, `cl-lib`, `json`, `url`, `seq`, `xref` and (for `ol-net.el`)
`ol`.  External Elisp packages are optional: `embark` for
`embark-net.el`, `evil` for `net-evil.el`, `package-lint` for the lint
check.  `embark-net.el` does not register at load time; the user
enables the global minor mode `embark-net-mode` after Embark loads.
`net-evil.el` requires evil, but `Package-Requires` stays free of it,
so a user without evil installs nothing extra.

Optional runtime data is listed in README.org.  No database is vendored
in the repository; the flake pins them as file inputs.

## Architecture

### Kind registry

`net-mode.el` keeps `net-kinds`, an alist of `KIND . PLIST`.  Each mode
file calls `net-register-kind` at load time with `:open`, `:sniff` and
`:priority`.  `net-sniff` requires the mode features lazily via
`net--kind-features` and tries the sniffers from the highest priority to
the lowest:

| Kind     | Priority | Notes                                                 |
| -------- | -------- | ----------------------------------------------------- |
| `cidr`   | 60       | Requires `/`                                          |
| `mac`    | 55       | Requires a colon, hyphen or Cisco dot group form      |
| `vsock`  | 50       | Accepts `CID:PORT` and `vsock://CID:PORT`             |
| `asn`    | 45       | Only `AS<n>` and `AS<n>.<m>` sniff; bare tokens stay free |
| `ip`     | 40       | IPv4/IPv6, including zones and IPv4 tails             |
| `domain` | 10       | Requires a dot and rejects all-numeric labels         |

`net-inspect` runs the dispatcher on the token at point (the
`net-address` thing type) or on a prompted string.  `net--thing-bounds`
drops trailing punctuation before the sniff, so an address followed by
a sentence period still resolves.  `net--thing-candidates` also looks
inside a URL, so the host of `https://example.org:8443/path` resolves
to `example.org`.

### Buffers and rendering

`net-display` creates or reuses `*net-KIND VALUE*`, calls the mode,
stores `net--kind`, `net--value` and `net--render-function`, then calls
`net-refresh`, which erases the buffer and runs the renderer.  The
refresh clears the modified flag with `set-buffer-modified-p nil`, and
both RDAP render paths clear it too, so a read-only inspect buffer
never shows a modified flag and never prompts on quit.  Renderers use
only the helpers in `net-mode.el`:

- `net-insert-heading`
- `net-insert-field` (button that copies the value)
- `net-insert-link` (button that opens another kind)
- `net-insert-link-list` (comma separated buttons on one wrapping line)
- `net-insert-text` (non-button, can span lines)
- `net-insert-warning`
- `net-set-summary` (header line classification, without the kind and
  the value, which the buffer name and the mode line already show)

`net-insert-heading` records each heading in the buffer-local
`net--headings` list, and `net--imenu-index` turns that list into the
Imenu index.  `net-mode-map` binds `TAB` and `<backtab>` to
`forward-button` and `backward-button`, so buttons work without a mouse
or `button-mode`, which would remove the buttons when the user turns it
off.

A mode sets `net--rdap-type` and `net--rdap-key` at the end of its
renderer when the value has an RDAP identity.

### Data access

Each reader caches on a key of (file, modification time, size), so
editing a database file invalidates the cache without a restart:

| Reader                       | Format                   | Cache variable                    |
| ---------------------------- | ------------------------ | --------------------------------- |
| `net--read-csv-file`         | CSV with multi-line cells| none, the callers cache           |
| `net--binary-table`          | Packed range table       | `net--binary-cache`               |
| `net-geo--data`              | 3-column CSV ranges      | `net-geo--cache`                  |
| `net-ip--registry-entries`   | IANA special-purpose CSV | `net-ip--registry-cache`          |
| `net-mac--registry-text`     | IEEE registry CSV        | `net-mac--registry-cache`         |
| `net-mac--manuf-table`       | Wireshark manuf          | `net-mac--manuf-cache`            |
| `net-asn--registry-rows`     | IANA AS numbers CSV      | `net-asn--registry-cache`         |
| `net-asn-entry`              | ipverse as-metadata JSON | `net-asn--memo`, `net-asn--table` |
| `net-asn--range-text`        | iptoasn range TSV (gzip) | `net-asn--range-cache`            |
| `net-domain--psl-load`       | Public Suffix List       | `net-domain--psl-cache`           |
| `net-vsock--services`        | IANA service names CSV   | `net-vsock--service-cache`        |

The AS metadata file is tens of megabytes.  `net-asn-entry` scans for
the one object whose `"asn"` key matches instead of parsing the array.
The regexp works with both pretty-printed and minified JSON, but it
expects `"asn"` as the first key of the object.  `net-asn--scan-shape-p`
checks that shape once per lookup, and any other file falls back to
`net-asn--table`, the full parse.  `net-asn-load-database` builds that
table for bulk sessions.

The IP to AS number tables are large too, and they are sorted.  The
Nix derivation packs them into a fixed-width table, and
`net-asn-ip-entry` binary searches it.  A raw upstream TSV or gzip file
still works: `net-asn--range-text` decompresses it once into
`net-asn--range-cache`, and `net-asn--search-row` binary searches the
line starts, so a lookup parses about twenty rows.  The reader gunzips
when the file starts with the gzip magic, not when the name ends in
`.gz`, because a Nix file input keeps no upstream name.  It uses
`zlib-decompress-region` instead of `insert-file-contents`, so a user
who turned off `auto-compression-mode` still gets an answer.  The
search keeps `low` on a line start, because a midpoint can fall inside
the current low line.  `net-ip--range-prefix` turns the covering
range into a prefix only when the range is a single aligned block, so
an aggregated iptoasn row renders as a range.

### Packed range tables

`tools/pack-network-data.el` runs at build time and writes four files:
`geo-ranges-v4.bin`, `geo-ranges-v6.bin`, `asn-ranges-v4.bin` and
`asn-ranges-v6.bin`.  The GeoIP CSV parse and the gzip pass therefore
leave the run time path: the first IP buffer went from 9.2 seconds to
0.05 seconds on IPv4, and from 13.5 seconds to 0.03 seconds on IPv6.

The layout is a 20-byte header, then fixed-width rows, then a string
table:

- header: magic `NETR`, format version u16, address width u8, number
  column count u8, string column count u8, three reserved bytes, row
  count u32, string table offset u32
- row: start address and end address as big-endian bytes, one u32 per
  number column, one u32 per string column
- string table: count u32, then each UTF-8 string with a u16 length

The format has one description.  `net--binary-header-type`,
`net--binary-row-type`, `net--binary-edge-type` and
`net--binary-names-type` are `bindat-type` values, and both the reader
and the packer use them.  The address widths and the column counts
reach the type through lexical variables, so `(uint (* 8 width))` and
`(vec numbers uint 32 t)` describe all four tables.  `bindat-unpack`
takes a byte offset, so a lookup unpacks one row in place and no
substring is allocated.  The packer allocates the output string once
and packs every row into it at a computed offset.

The header carries the layout, so `net--binary-table` takes the
expected width and column counts and signals an error on a mismatch.
Bump the format version in `net--binary-version` and in the packer
together.  A file without the magic bytes is not a packed table, so the
raw CSV and TSV readers stay in use for users outside Nix.  The flake
check `checks.data-tables` runs both readers against the real
derivation.

### Address arithmetic

IPv4 and IPv6 values are integers.  Emacs bignums make the same prefix
arithmetic work for both families:

- `net-ip--block` parses `ADDRESS/PREFIX` into `:start` and `:last`
- `net-ip-in-block-p` tests containment
- `net-cidr-parse` computes network, last address, mask and host counts

`net-ip--format-ipv6` implements RFC 5952 compression: lowercase, no
leading zeros, longest run of at least two zero groups replaced by `::`.

### Punycode

`net-domain--punycode-encode` implements RFC 3492.  Emacs does not ship
`punycode.el` (it comes from libidn), so the package carries its own
encoder.  IDNA normalization is limited to lowercasing; the buffer says
so when a label is not ASCII.

The Public Suffix List writes IDN rules in Unicode.  The lookup uses
the Punycode form of the name, so `net-domain--psl-load` stores a
Punycode alias for every IDN rule.

### RDAP

`net-rdap` calls `url-retrieve` and renders a section at the end of the
current buffer in the callback.  A second lookup replaces that section
instead of appending another; a buffer-local `net--rdap-start` marker
delimits it.  `net--rdap-begin-section` performs the replacement, so
the timeout path and the callback share it.  The callback parses the
RDAP JSON and renders handle, name, type, country, addresses, status,
events, entities and remarks.  An answer with `errorCode` renders the
code, the title and the description instead of the fields, and an
unparseable answer renders the HTTP status.  Remarks fill to
`fill-column' because the buffer truncates lines.

A buffer-local `net--rdap-in-flight` flag prevents duplicate requests.
`net-rdap-timeout` seconds later, `net--rdap-abandon` clears the flag
and renders a warning, so a stalled connection cannot block the buffer
for the session; a late answer still replaces that warning.  The
callback hands its response buffer to `url-mark-buffer-as-dead`, so
repeated lookups do not pile up one buffer each.  No automatic refresh
or timer may call this command.

### Evil

`net-evil.el` is a second library, so the modes never require evil.
It requires evil and `net-mode`, and it binds keys in normal and
visual state only.

Evil state maps take precedence over a major mode map, so `RET`, `q`,
`w`, `b` and `i` would run an evil command instead of the inspect
command.  The bindings put the commands of `net-mode-map` back:
`RET` pushes a button, `q` quits the window, `gr` reverts, `w` copies
the value, `b` fetches RDAP and `i` inspects the address at point.
The motions `j`, `k`, `gg`, `G`, `C-d`, `C-u`, `/`, `n` and `N` stay
evil.  Visual state binds only `RET`, because it needs its text
objects.  Evil keeps `TAB` for its jump motion, so `net-evil-keys`
leaves the button motion of `net-mode-map` out.

`net-evil-keys` and `net-evil-visual-keys` hold the key tables.
`net-evil--bind` feeds them to `evil-define-minor-mode-key` for the
private minor mode `net-evil-local-mode`.  `net-evil-mode` is the
global switch.  It adds `net-evil--enable-buffer` to
`after-change-major-mode-hook`, because the six address modes derive
from `net-mode`, and turns the local mode on in every existing inspect
buffer.  Turning it off removes the hook and the local mode, so the
buffer falls back to `net-mode-map`.

## Building

```sh
nix build                  # package
nix flake check            # package + ERT + lint + checkdoc + data + treefmt
nix develop                # Emacs with package-lint, embark and evil
nix fmt                    # nixfmt via treefmt
nix flake update           # refresh pinned database files
```

The data derivation needs `emacs-nox` and four Elisp files: `net-mode.el`
for the `bindat` types, `net-geo.el`, `net-asn.el` and `net-ip.el` for
the readers and the address parser, and `tools/pack-network-data.el`
for the packer.  Run the packer by hand with the command in its
commentary.

The package is `lib.makeOverridable`, so a consumer can substitute the
Emacs, its package set, the build function, the evil package or the
database derivation:

```nix
inputs.network-modes.packages.${system}.default.override {
  emacs = pkgs.emacs-nox;
}
```

The flake passes the commit-derived version to the builder, because a
plain import of the expression cannot know it.  The builder defaults to
`0.1.0`, follows an `emacs` override with `emacsPackages` and `evil`,
and takes any extra database derivation through `data`.

Byte-compile with warnings as errors:

```sh
for f in net-*.el ol-net.el embark-net.el; do
  emacs --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
    -f batch-byte-compile "$f"
done
```

`net-evil.el` needs evil on the load path.  Add the evil elisp
directory with `-L` for that file, the way the flake check does.

## Testing

```sh
emacs -Q --batch -L . -l net-tests.el -f ert-run-tests-batch-and-exit
```

`net-evil-tests.el` needs evil on the load path.  Every test in it skips
when evil is absent, so a checkout without evil still passes:

```sh
emacs -Q --batch -L . -L "$EVIL_DIR" \
  -l net-tests.el -l net-evil-tests.el \
  -f ert-run-tests-batch-and-exit
```

The suite uses temporary files for every database, so it never depends
on the store paths of the Nix build.  Test files carry the `-tests.el`
suffix, which package-build and the lint gates exclude.

`nix flake check` runs four gates:

- `packages.network-modes`: `melpaBuild` byte-compiles with warnings as
  errors, then runs both ERT suites in its `checkPhase`.  The build
  supplies the evil elisp directory to `preInstall` and to the check,
  because `net-evil.el` is optional and the package declares no evil
  dependency.
- `checks.package-lint`: ELPA policy.  The package shares the short
  `net-` prefix, so the check whitelists it.
- `checks.checkdoc`: docstring conventions.  checkdoc exits 0 on
  findings, so the check fails on non-empty output.
- `checks.data-tables`: runs the packed table readers against the real
  data derivation, so the packer and the Elisp decoder cannot drift
  apart unnoticed.

## Conventions

- Lines stay under 80 columns; docstrings wrap at the same width.
- Parsers and formatters are pure.  Only renderers, commands and the
  database readers have side effects.
- Side effect free helpers carry `(declare (pure t) (side-effect-free t))`:
  the address formatters, the prefix and block arithmetic, the Punycode
  encoder, `net--split-csv-line` and `net-asn-classification`.  A parser
  that runs a regexp keeps no declaration, because `string-match`,
  `split-string` and `string-trim` clobber the match data and
  `case-fold-search` changes the result.  A reader must never carry one,
  because it fills a cache.
- `defcustom` names carry the `net-` prefix.  Public functions are
  `net-KIND-*`; internal helpers use `net--`.
- The package name equals the entry library: `pname =
  "network-modes"` in the flake and `network-modes.el` in the source.
  `use-package SYMBOL` expands to `(require SYMBOL)` and `:ensure t`
  looks up the package of that name, so the two names must agree.
  Users configure the suite through
  `(use-package network-modes :config ...)`, and the README points
  there first.  Do not point users at `net-mode` as the package door,
  and do not require `network-modes` from another package file.  The
  short `net-` prefix stays: the lint gate whitelists it, because the
  package name spells the root out in full.
- Field labels and values render through the helpers in `net-mode.el`;
  do not insert raw text in a renderer.  `net--insert-label` keeps at
  least one space after long labels.
- Unknown values render as `unknown`; invalid input signals
  `user-error` from the inspect command, never from a renderer.
- Read CSV through `net--read-csv-file`, so a quoted field can span
  lines.  Normalize IANA registry rows with `net-ip--registry-blocks`:
  the Address Block column can carry a ` [2]` footnote and can hold
  several comma separated blocks.
- The IANA special-purpose CSV is the primary classification source
  for both `net-ip-mode` and `net-cidr-mode`.  The built-in table in
  `net-ip--builtin-blocks` is the offline fallback, and its `:always`
  rows join the CSV because the registries omit multicast.
- `net-cidr-registry-file` and `net-cidr-registry-file-v6` alias the
  `net-ip-registry-file` options of the same name.
- Data files are never vendored.  Add a new one as a flake file input,
  a symlink in the data derivation inside `flake.nix`, and a `defcustom` defaulting to
  `(net-data-file "upstream-name")`.  The IEEE registries keep their
  upstream file names inside `net-mac-registry-directory`.
- A derived file carries its own name, not the upstream one.  The four
  packed range tables come from `tools/pack-network-data.el`, whose
  `bindat` types sit beside `net--binary-version` in `net-mode.el`.
  Keep the raw upstream file reachable too, so the CSV and TSV readers
  stay testable.
- MAC vendor data uses the IEEE registries.  MA-S and IAB share the
  36-bit prefix length and CID shares 24 bits with MA-L, so the lookup
  tries the files in `net-mac--registry-files` order.  The optional
  Wireshark manuf table keys entries by `BITS:PREFIX`, which makes the
  longest mask win.
- Capture `match-string` results before calling another function: the
  callee may run `string-match` and clobber the match data.
- Do not use `concat` with integer characters; use `char-to-string`.
- `net-evil.el` follows the `net-` prefix and `evil-define-key` stays
  unused: it is a macro, so a file that must compile without evil
  cannot call it.  `net-evil--bind` calls the function
  `evil-define-minor-mode-key` and `key-parse` converts every key
  description, because `define-key` reads a plain string as literal
  characters, so `"RET"` would bind three keys.  A new command in
  `net-mode-map` belongs in `net-evil-keys`, and in
  `net-evil-visual-keys` when visual state needs it.
- `define-minor-mode` defines a defcustom, so a mode without
  `:group 'net` fails byte-compilation with "fails to specify
  containing group".  The evil minor-mode maps stay in
  `evil-minor-mode-keymaps-alist` against the mode symbol, and Emacs
  activates a map only while that symbol holds a value, so turning
  `net-evil-local-mode` on or off needs no `evil-normalize-keymaps`
  call.
- `net-evil-tests.el` calls `evil-local-mode` and then reads
  `key-binding`, so it tests what the keyboard sees, not the keymap
  directly.  It declares every evil function it calls, so a checkout
  without evil still byte-compiles.

## TODO

- RPKI/ROA validation state per prefix
- PeeringDB data for AS numbers
- DNSBL lookups
- Full IDNA (UTS #46) normalization
- MMDB input for GeoIP
- A port/service mode built on the IANA registry
