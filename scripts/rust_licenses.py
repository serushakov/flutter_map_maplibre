#!/usr/bin/env python3
"""Writes the license notices for the Rust crates linked into the Android
static archive (maplibre-native-ffi's platform crate: HTTP, TLS, image
decoding).

usage: scripts/rust_licenses.py <maplibre-native-ffi checkout> <output.md>

Walks `cargo tree` for the aarch64-linux-android target — the exact set the
prebuilt links — and copies each crate's own license files out of the local
cargo registry. The few crates that publish no license file get the standard
text of the license their Cargo.toml declares, attributed to its authors.
"""

import json
import subprocess
import sys
from pathlib import Path

MIT = """Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE."""

LICENSE_PREFIXES = ("license", "licence", "copying", "unlicense", "notice")


def main() -> None:
    ffi, out = Path(sys.argv[1]), Path(sys.argv[2])
    meta = json.loads(
        subprocess.check_output(
            ["cargo", "metadata", "--locked", "--format-version", "1"],
            cwd=ffi,
        )
    )
    by_id = {p["id"]: p for p in meta["packages"]}
    tree = subprocess.check_output(
        [
            "cargo", "tree", "-p", "maplibre-native-platform",
            "--target", "aarch64-linux-android", "-e", "normal",
            "--prefix", "none", "-f", "{p}", "--locked",
        ],
        cwd=ffi,
        text=True,
    )
    wanted = set()
    for line in tree.splitlines():
        name, version = line.split()[:2]
        wanted.add((name, version.lstrip("v")))

    crates = sorted(
        (p for p in by_id.values()
         if (p["name"], p["version"]) in wanted and p["source"]),
        key=lambda p: p["name"],
    )

    parts = [
        "# Rust crates linked into libmaplibre-native-c.a (Android)\n",
        f"{len(crates)} crates, from `cargo tree` for aarch64-linux-android.\n",
    ]
    for p in crates:
        root = Path(p["manifest_path"]).parent
        files = sorted(
            f for f in root.iterdir()
            if f.is_file() and f.name.lower().startswith(LICENSE_PREFIXES)
        )
        parts.append(f"\n## {p['name']} {p['version']}\n")
        parts.append(f"License: {p['license']}  ")
        if p.get("repository"):
            parts.append(f"Source: {p['repository']}\n")
        if files:
            for f in files:
                parts.append(f"\n### {f.name}\n\n```\n{f.read_text().strip()}\n```\n")
        elif "MIT" in (p["license"] or ""):
            authors = ", ".join(p.get("authors") or [p["name"] + " authors"])
            parts.append(
                "\n(No license file published; standard MIT text below.)\n\n"
                f"```\nCopyright (c) {authors}\n\n{MIT}\n```\n"
            )
        else:
            sys.exit(f"{p['name']} {p['version']}: no license file, not MIT")

    out.write_text("".join(parts))
    print(f"{out}: {len(crates)} crates")


if __name__ == "__main__":
    main()
