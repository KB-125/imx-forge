#!/usr/bin/env python3
"""Merge the per-component compile_commands.json files into one database.

Components: QEMU, U-Boot, Linux, BusyBox.  Buildroot is intentionally not
included: it has no native compile-commands support, its package builds happen
in out/release-latest/buildroot/build/<pkg>/ copies, and the tree itself only
contains a handful of host tools.

Generated databases live in the corresponding build directories:

    out/qemu/build/compile_commands.json   (meson writes it during configure)
    out/uboot/compile_commands.json        (scripts/gen_compile_commands.py)
    out/linux/compile_commands.json        (make compile_commands.json)
    out/busybox/compile_commands.json      (kernel gen_compile_commands.py)

The merged database is written to out/compile_commands.json.  The repository
root .clangd points clangd at out/, so no database copy into third_party/ is
needed.

Cross-compiler entries are rewritten to the absolute compiler path because
clangd's --query-driver matches the resolved, absolute executable path (a bare
arm-none-linux-gnueabihf-gcc is resolved through PATH and may not match the
glob).  Host entries (gcc/cc, used by QEMU) are left untouched.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys

# (component, source tree, database produced by the component)
COMPONENTS = [
    ("qemu", "third_party/qemu", "out/qemu/build/compile_commands.json"),
    ("uboot", "third_party/uboot-mainline", "out/uboot/compile_commands.json"),
    ("linux", "third_party/linux_mainline", "out/linux/compile_commands.json"),
    ("busybox", "third_party/busybox", "out/busybox/compile_commands.json"),
]

CROSS_PREFIX = "arm-none-linux-gnueabihf-"


def entry_file(entry: dict, root: str) -> str | None:
    """Return the absolute source path of a database entry."""
    path = entry.get("file")
    if not path:
        return None
    if not os.path.isabs(path):
        path = os.path.join(root, entry.get("directory", "."), path)
    return os.path.realpath(path)


def entry_dir(entry: dict, root: str) -> str:
    directory = entry.get("directory", ".")
    if not os.path.isabs(directory):
        directory = os.path.join(root, directory)
    return os.path.realpath(directory)


def is_under(path: str, directory: str) -> bool:
    try:
        return os.path.commonpath([path, directory]) == directory
    except ValueError:
        return False


def rewrite_cross_compiler(entry: dict, cross_gcc: str) -> bool:
    """Replace a bare cross-compiler argv[0] with its absolute path."""
    if not cross_gcc:
        return False

    args = entry.get("arguments")
    if isinstance(args, list):
        # pkgconf/bear may prepend ccache; the compiler is within the first two.
        for index in range(min(2, len(args))):
            if os.path.basename(str(args[index])).startswith(CROSS_PREFIX):
                args[index] = cross_gcc
                return True
        return False

    command = entry.get("command")
    if not command:
        return False
    parts = command.split(None, 1)
    if parts and os.path.basename(parts[0]).startswith(CROSS_PREFIX):
        entry["command"] = cross_gcc + ((" " + parts[1]) if len(parts) > 1 else "")
        return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--root",
        default=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
        help="repository root (default: two levels above this script)",
    )
    parser.add_argument(
        "--output",
        default="out/compile_commands.json",
        help="merged database path, relative to --root (default: %(default)s)",
    )
    parser.add_argument(
        "--cross-gcc",
        default=shutil.which(CROSS_PREFIX + "gcc") or "",
        help="absolute path of the ARM cross compiler (default: found via PATH)",
    )
    parser.add_argument(
        "--allow-missing",
        action="store_true",
        help="do not fail when a component database is missing",
    )
    args = parser.parse_args()

    root = os.path.realpath(args.root)
    cross_gcc = os.path.realpath(args.cross_gcc) if args.cross_gcc else ""
    if cross_gcc and not os.access(cross_gcc, os.X_OK):
        print(f"error: cross compiler is not executable: {cross_gcc}", file=sys.stderr)
        return 1

    merged: dict[str, dict] = {}
    total_entries = 0
    missing_databases: list[str] = []

    print(f"{'component':10} {'entries':>9} {'kept':>6} {'dup':>5} {'dropped':>8}")
    for name, source_rel, database_rel in COMPONENTS:
        source_dir = os.path.join(root, source_rel)
        database = os.path.join(root, database_rel)
        if not os.path.exists(database):
            missing_databases.append(database_rel)
            print(f"{name:10} {'MISSING':>9}  ({database_rel})")
            continue

        with open(database, encoding="utf-8") as stream:
            entries = json.load(stream)
        total_entries += len(entries)

        kept = duplicated = dropped = rewritten = 0
        for entry in entries:
            source = entry_file(entry, root)
            if source is None or not is_under(source, source_dir):
                dropped += 1
                continue
            if source in merged:
                duplicated += 1
                continue
            # Normalize paths so clangd and deduplication see identical entries.
            if not os.path.isabs(entry.get("file", "")):
                entry["file"] = source
            entry["directory"] = entry_dir(entry, root)
            if rewrite_cross_compiler(entry, cross_gcc):
                rewritten += 1
            merged[source] = entry
            kept += 1

        print(
            f"{name:10} {len(entries):9} {kept:6} {duplicated:5} {dropped:8}"
            f"   (cross compiler rewritten: {rewritten})"
        )

    if missing_databases and not args.allow_missing:
        print(
            "\nerror: missing component database(s):\n  "
            + "\n  ".join(missing_databases)
            + "\nBuild the component first (see scripts/build_helper/).",
            file=sys.stderr,
        )
        return 1

    output = os.path.join(root, args.output)
    os.makedirs(os.path.dirname(output), exist_ok=True)
    with open(output, "w", encoding="utf-8") as stream:
        json.dump([merged[key] for key in sorted(merged)], stream, separators=(",", ":"))
        stream.write("\n")

    size_mb = os.path.getsize(output) / 1e6
    print(f"\nmerged: {len(merged)} entries from {total_entries} database entries")
    print(f"output: {output} ({size_mb:.1f} MB)")

    if cross_gcc:
        directory = os.path.dirname(cross_gcc)
        print(f"clangd: --query-driver={directory}/{CROSS_PREFIX}*")
    else:
        print("warning: no cross compiler found; clangd may not resolve ARM headers", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
