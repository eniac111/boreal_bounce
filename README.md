# Boreal Bounce

A from-scratch Godot 4 reimplementation of the puzzle game Frozen-Bubble, reusing the
original artwork, sounds, levels and translations. GPL-2, see `COPYING` and `CREDITS.md`.

## Installing

Every release carries the same five downloads plus `SHA256SUMS`:

| File | What it is |
|---|---|
| `boreal-bounce-<v>-linux-x86_64.tar.gz` | the game for Linux on Intel and AMD |
| `boreal-bounce-<v>-linux-arm64.tar.gz` | the game for 64-bit ARM (Raspberry Pi 4 and 5, ARM laptops) |
| `boreal-bounce-<v>-linux-arm32.tar.gz` | the game for 32-bit ARM (older Pi systems) |
| `boreal-bounce-<v>-windows-x86_64.zip` | the game for Windows |
| `boreal-bounce-<v>-web.zip` | the web build, unpack it into any web server |
| `boreal-bounce-<v>-dedicated-server-x86_64.tar.gz` | headless relay server for a VPS |
| `boreal-bounce-<v>-dedicated-server-arm64.tar.gz` | the same server for an ARM VPS |
| `boreal-bounce-<v>-x86_64.flatpak` | Flatpak bundle for Linux desktops |
| `boreal-bounce-<v>-aarch64.flatpak` | the same bundle for 64-bit ARM |

Every desktop build is one self-contained executable: the data pack is embedded, so the file
can be renamed or installed on its own. There is no macOS build yet. Every push and pull request builds the same set through
`.github/workflows/build.yml` and keeps it as run artifacts for two weeks, stamped `0.0.0`;
those are for testing and are never published. To install the Flatpak:

```sh
flatpak install --user boreal-bounce-1.2.3-x86_64.flatpak
flatpak run info.petrovs.BorealBounce
```

## Releasing

Releases are cut by hand: create a release in the GitHub UI on master, tag it `v1.2.3` and
publish it. Publishing starts `.github/workflows/release.yml`, which builds the deliverables
and uploads them to that release as assets. Nothing needs editing beforehand, the version
comes from the tag. Write the release notes yourself; the workflow only adds files.

The workflow refuses a tag that is not of the form `v1.2.3` or that does not point at a commit
on master. It stamps the version into `project.godot`, the Windows export preset and the
AppStream metadata (`tools/set_version.py`), runs the tests, exports Linux, Windows, web and
the dedicated server, builds the Flatpak from `packaging/flatpak/`, and attaches everything
plus `SHA256SUMS` to the release. Re-running it (Actions, "release", Run workflow, with the
tag) replaces the assets. To try the same build by hand:

```sh
python3 tools/set_version.py 1.2.3
godot --headless --path . --export-release "Linux" dist/boreal_bounce
flatpak-builder --force-clean --repo=repo build-flatpak packaging/flatpak/info.petrovs.BorealBounce.yml
flatpak build-bundle repo boreal-bounce.flatpak info.petrovs.BorealBounce
```

The Flatpak manifest reads `dist/boreal_bounce` with no architecture suffix, so the same file
packages either build; pass `--arch=aarch64` to both flatpak commands (and export the arm64
build to that name) for the ARM bundle.
