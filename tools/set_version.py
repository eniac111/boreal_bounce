#!/usr/bin/env python3
"""Stamp a release version into the project, the export presets and the Flatpak metadata.

The release workflow runs this with the tag it was triggered by (v1.2.3 -> 1.2.3) so the
built binaries and the AppStream data all carry the same number. Run it by hand only to try
a release build locally; the committed files keep whatever version was stamped last.
"""
import argparse
import datetime
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
METAINFO = ROOT / "packaging" / "flatpak" / "info.petrovs.BorealBounce.metainfo.xml"
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")


def set_project_version(version: str) -> str:
    path = ROOT / "project.godot"
    text = path.read_text(encoding="utf-8")
    if "config/version=" in text:
        text = re.sub(r'config/version=".*"', f'config/version="{version}"', text, count=1)
    else:
        text = text.replace('config/name="Boreal Bounce"',
                            f'config/name="Boreal Bounce"\nconfig/version="{version}"', 1)
    path.write_text(text, encoding="utf-8")
    return "project.godot"


def set_preset_versions(version: str) -> str:
    path = ROOT / "export_presets.cfg"
    text = path.read_text(encoding="utf-8")
    for key in ("application/product_version", "application/file_version"):
        if f"{key}=" in text:
            text = re.sub(rf'{key}=".*"', f'{key}="{version}"', text)
        else:  # the Windows preset is the only one that carries version fields
            text = text.replace('application/product_name="Boreal Bounce"',
                                f'{key}="{version}"\napplication/product_name="Boreal Bounce"', 1)
    path.write_text(text, encoding="utf-8")
    return "export_presets.cfg"


def set_metainfo_release(version: str, date: str) -> str:
    text = METAINFO.read_text(encoding="utf-8")
    entry = f'    <release version="{version}" date="{date}"/>'
    if f'version="{version}"' in text:
        text = re.sub(rf'    <release version="{re.escape(version)}"[^/]*/>', entry, text, count=1)
    else:
        text = text.replace("  <releases>\n", f"  <releases>\n{entry}\n", 1)
    # drop the 0.0.0 placeholder once a real release exists
    text = re.sub(r'\s*<release version="0\.0\.0"[^/]*/>', "", text)
    METAINFO.write_text(text, encoding="utf-8")
    return METAINFO.relative_to(ROOT).as_posix()


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("version", help="release version, with or without the leading v (1.2.3)")
    ap.add_argument("--date", default=datetime.date.today().isoformat(), help="release date for the AppStream entry")
    args = ap.parse_args()
    version = args.version.lstrip("v")
    if not VERSION_RE.match(version):
        sys.exit(f"version must look like 1.2.3, got {args.version!r}")
    touched = [set_project_version(version), set_preset_versions(version), set_metainfo_release(version, args.date)]
    print(f"stamped {version} into " + ", ".join(touched))


if __name__ == "__main__":
    main()
