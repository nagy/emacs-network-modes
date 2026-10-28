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

| File               | Purpose                                                           |
| ------------------ | ----------------------------------------------------------------- |
| `network-modes.el` | Entry point: requires the base mode and all six modes             |
| `net-mode.el`      | Base mode, kind registry, dispatcher, renderer, bookmarks, RDAP   |
| `net-geo.el`       | Country lookup from PDDL range CSVs, with binary search cache     |
| `net-ip.el`        | IP parsing/formatting, special-purpose blocks, registry reader, IP mode |
| `net-cidr.el`      | Prefix arithmetic, CIDR mode                                      |
| `net-mac.el`       | MAC/EUI-64 parsing, bit flags, IEEE and manuf vendor lookup       |
| `net-asn.el`       | AS number parsing, IANA registry, ipverse metadata, ASN mode      |
| `net-domain.el`    | Domain parsing, Punycode encoder, PSL lookup, domain mode         |
| `net-vsock.el`     | AF_VSOCK parsing, `sockaddr_vm` layout, service names, vsock mode |
| `ol-net.el`        | Opt-in Org link types (`net-*:` and `net:`)                       |
| `embark-net.el`    | Opt-in Embark target and actions (`embark-net-mode`)              |
| `net-xref.el`      | Opt-in xref backend                                               |
| `net-tests.el`     | ERT suite (63 tests)                                              |
| `flake.nix`        | Database inputs and derivation, `melpaBuild`, outputs and checks  |
| `README.org`       | User documentation                                                |
| `LICENSE`          | AGPL-3.0-or-later                                                 |

## Dependencies

Emacs 31.1 or newer.  All Elisp dependencies are built in: `bookmark`,
`button`, `cl-lib`, `json`, `url`, `seq`, `xref` and (for `ol-net.el`)
`ol`.  External Elisp packages are optional: `embark` for
`embark-net.el`, `package-lint` for the lint check.  `embark-net.el`
does not register at load time; the user enables the global minor mode
`embark-net-mode` after Embark loads.

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
a sentence period still resolves.

### Buffers and rendering

`net-display` creates or reuses `*net-KIND VALUE*`, calls the mode,
stores `net--kind`, `net--value` and `net--render-function`, then calls
`net-refresh`, which erases the buffer and runs the renderer.  Renderers
use only the helpers in `net-mode.el`:

- `net-insert-heading`
- `net-insert-field` (button that copies the value)
- `net-insert-link` (button that opens another kind)
- `net-insert-link-list` (comma separated buttons on one wrapping line)
- `net-insert-text` (non-button, can span lines)
- `net-insert-warning`
- `net-set-summary` (header line classification)

A mode sets `net--rdap-type` and `net--rdap-key` at the end of its
renderer when the value has an RDAP identity.

### Data access

Each reader caches on a key of (file, modification time, size), so
editing a database file invalidates the cache without a restart:

| Reader                       | Format                   | Cache variable                    |
| ---------------------------- | ------------------------ | --------------------------------- |
| `net--read-csv-file`         | CSV with multi-line cells| none, the callers cache           |
| `net-geo--data`              | 3-column CSV ranges      | `net-geo--cache`                  |
| `net-ip--registry-entries`   | IANA special-purpose CSV | `net-ip--registry-cache`          |
| `net-mac--registry-text`     | IEEE registry CSV        | `net-mac--registry-cache`         |
| `net-mac--manuf-table`       | Wireshark manuf          | `net-mac--manuf-cache`            |
| `net-asn--registry-rows`     | IANA AS numbers CSV      | `net-asn--registry-cache`         |
| `net-asn-entry`              | ipverse as-metadata JSON | `net-asn--memo`, `net-asn--table` |
| `net-domain--psl-load`       | Public Suffix List       | `net-domain--psl-cache`           |
| `net-vsock--services`        | IANA service names CSV   | `net-vsock--service-cache`        |

The AS metadata file is tens of megabytes.  `net-asn-entry` scans for
the one object whose `"asn"` key matches instead of parsing the array.
The regexp works with both pretty-printed and minified JSON, but it
expects `"asn"` as the first key of the object.  `net-asn--scan-shape-p`
checks that shape once per lookup, and any other file falls back to
`net-asn--table`, the full parse.  `net-asn-load-database` builds that
table for bulk sessions.

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
delimits it.  The callback parses the RDAP JSON and renders handle,
name, type, country, addresses, status, events, entities and remarks.
A buffer-local `net--rdap-in-flight` flag prevents duplicate requests.
No automatic refresh or timer may call this command.

## Building

```sh
nix build                  # package
nix flake check            # package + ERT + package-lint + checkdoc + treefmt
nix develop                # Emacs with package-lint and embark
nix fmt                    # nixfmt via treefmt
nix flake update           # refresh pinned database files
```

Byte-compile with warnings as errors:

```sh
for f in net-*.el ol-net.el embark-net.el; do
  emacs --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
    -f batch-byte-compile "$f"
done
```

## Testing

```sh
emacs -Q --batch -L . -l net-tests.el -f ert-run-tests-batch-and-exit
```

The suite uses temporary files for every database, so it never depends
on the store paths of the Nix build.  Test files carry the `-tests.el`
suffix, which package-build and the lint gates exclude.

`nix flake check` runs three gates:

- `packages.network-modes`: `melpaBuild` byte-compiles with warnings as
  errors, then runs the ERT suite in its `checkPhase`.
- `checks.package-lint`: ELPA policy.  The package shares the short
  `net-` prefix, so the check whitelists it.
- `checks.checkdoc`: docstring conventions.  checkdoc exits 0 on
  findings, so the check fails on non-empty output.

## Conventions

- Lines stay under 80 columns; docstrings wrap at the same width.
- Parsers and formatters are pure.  Only renderers, commands and the
  database readers have side effects.
- `defcustom` names carry the `net-` prefix.  Public functions are
  `net-KIND-*`; internal helpers use `net--`.
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
- MAC vendor data uses the IEEE registries.  MA-S and IAB share the
  36-bit prefix length and CID shares 24 bits with MA-L, so the lookup
  tries the files in `net-mac--registry-files` order.  The optional
  Wireshark manuf table keys entries by `BITS:PREFIX`, which makes the
  longest mask win.
- Capture `match-string` results before calling another function: the
  callee may run `string-match` and clobber the match data.
- Do not use `concat` with integer characters; use `char-to-string`.

## TODO

- RPKI/ROA validation state per prefix
- PeeringDB data for AS numbers
- DNSBL lookups
- Full IDNA (UTS #46) normalization
- MMDB input for GeoIP
- A port/service mode built on the IANA registry
