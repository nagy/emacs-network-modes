#!/usr/bin/env python3
"""Pack the pinned network range databases into fixed-width tables.

The Emacs readers binary search these files, so each row holds the
start and end address, a few 32-bit numbers and a few indexes into an
interned string table.  No text parsing and no decompression happens
at run time.

Layout, little endian:

    0   4  magic "NETR"
    4   2  format version
    6   1  address width in bytes, 4 or 16
    7   1  number of 32-bit number columns
    8   1  number of string columns
    9   1  reserved, zero
    10  2  reserved, zero
    12  4  row count
    16  4  offset of the string table
    20     rows

A row holds the start and end address as big-endian bytes, then one
32-bit number per number column, then one 16-bit index per string
column.  The string table holds a 32-bit count, then one UTF-8 string
per entry, each prefixed with its 16-bit length.

Keep the format version in sync with `net--binary-version' in
net-mode.el.
"""

import argparse
import gzip
import ipaddress
import struct
import sys

MAGIC = b"NETR"
VERSION = 1
HEADER = struct.Struct("<4sHBBBBHII")
COUNT = struct.Struct("<I")
LENGTH = struct.Struct("<H")
NUMBER = struct.Struct("<I")
INDEX = struct.Struct("<I")


def pack_table(path, width, numbers, strings, rows):
    """Write ROWS to PATH with WIDTH bytes per address."""
    rows.sort(key=lambda row: row[0])
    previous_end = None
    for row in rows:
        start, end = row[0], row[1]
        if start > end:
            raise ValueError("row ends before it starts: %r" % (row,))
        if previous_end is not None and start <= previous_end:
            raise ValueError("rows overlap or are unsorted: %r" % (row,))
        previous_end = end

    names = []
    indexes = {}
    for row in rows:
        for text in row[3]:
            if text not in indexes:
                indexes[text] = len(names)
                names.append(text)
    if len(names) > 0xFFFFFFFF:
        raise ValueError("%s holds too many distinct strings" % path)

    row_size = 2 * width + 4 * numbers + 4 * strings
    strings_offset = HEADER.size + len(rows) * row_size

    blob = bytearray()
    blob += HEADER.pack(MAGIC, VERSION, width, numbers, strings, 0, 0,
                        len(rows), strings_offset)
    for start, end, values, texts in rows:
        blob += start.to_bytes(width, "big")
        blob += end.to_bytes(width, "big")
        for value in values:
            blob += NUMBER.pack(value)
        for text in texts:
            blob += INDEX.pack(indexes[text])

    blob += COUNT.pack(len(names))
    for name in names:
        encoded = name.encode("utf-8")
        if len(encoded) > 0xFFFF:
            raise ValueError("string is too long for %s" % path)
        blob += LENGTH.pack(len(encoded))
        blob += encoded

    with open(path, "wb") as handle:
        handle.write(blob)
    print(
        "%s: %d rows, %d strings, %d bytes"
        % (path, len(rows), len(names), len(blob)),
        file=sys.stderr,
    )


def geo_rows(path):
    """Return the PDDL country rows of the CSV file PATH."""
    rows = []
    with open(path, newline="", encoding="utf-8") as handle:
        for record in handle:
            fields = record.rstrip("\n").split(",")
            if len(fields) < 3 or fields[0] == "ip_range_start":
                continue
            rows.append(
                (
                    int(ipaddress.ip_address(fields[0])),
                    int(ipaddress.ip_address(fields[1])),
                    (),
                    (fields[2],),
                )
            )
    return rows


def is_gzip(path):
    """Return True when PATH starts with the gzip magic bytes."""
    with open(path, "rb") as handle:
        return handle.read(2) == b"\x1f\x8b"


def asn_rows(path):
    """Return the iptoasn rows of the gzip or plain TSV file PATH."""
    opener = gzip.open if is_gzip(path) else open
    rows = []
    with opener(path, "rt", encoding="utf-8") as handle:
        for line in handle:
            fields = line.rstrip("\n").split("\t")
            if len(fields) < 5:
                continue
            rows.append(
                (
                    int(ipaddress.ip_address(fields[0])),
                    int(ipaddress.ip_address(fields[1])),
                    (int(fields[2]),),
                    (fields[3], fields[4]),
                )
            )
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--geo-v4", required=True, help="PDDL IPv4 CSV file")
    parser.add_argument("--geo-v6", required=True, help="PDDL IPv6 CSV file")
    parser.add_argument("--asn-v4", required=True, help="iptoasn IPv4 TSV file")
    parser.add_argument("--asn-v6", required=True, help="iptoasn IPv6 TSV file")
    parser.add_argument("--out-dir", required=True, help="output directory")
    args = parser.parse_args()

    tables = [
        ("geo-ranges-v4.bin", 4, 0, 1, geo_rows(args.geo_v4)),
        ("geo-ranges-v6.bin", 16, 0, 1, geo_rows(args.geo_v6)),
        ("asn-ranges-v4.bin", 4, 1, 2, asn_rows(args.asn_v4)),
        ("asn-ranges-v6.bin", 16, 1, 2, asn_rows(args.asn_v6)),
    ]
    for name, width, numbers, strings, rows in tables:
        pack_table(
            "%s/%s" % (args.out_dir, name), width, numbers, strings, rows
        )


if __name__ == "__main__":
    main()
