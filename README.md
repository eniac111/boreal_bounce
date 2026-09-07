# Boreal Bounce

A from-scratch Godot 4 reimplementation of the puzzle game Frozen-Bubble, reusing the
original artwork, sounds, levels and translations. GPL-2, see `COPYING` and `CREDITS.md`.

## Working on it

- Engine: Godot 4.7 (Compatibility renderer), GDScript.
- `PLAN.md` describes the port: goals, architecture, milestones.
- Assets under `assets/` are generated from the original game's `../share/` tree by
  `tools/import_assets.py` (needs Python 3, Pillow and numpy). Do not edit them in place; re-run
  the script. `assets/PROVENANCE.md` lists where every file came from. `assets/gfx_hd/` holds
  2x upscaled copies used on large screens; replace any of them with a better upscale of the
  same size to improve the look further.
- Tests: `godot --headless --path . -s tests/run_tests.gd`
- Run: `godot --path .`
- Network play: "LAN game" finds hosts on the local network (UDP broadcast on port 1512,
  game traffic on UDP 1511). "NET game" connects to the public server set in Options (or a
  typed host:port); on a relay you create a room and share its four-letter code. Anyone can
  also host from the lobby (H): the game asks the router to open the port via UPnP and shows
  the public address to give to friends. A headless relay server for a VPS:
  `godot --headless --path . -- --server=1511` (or the "Linux dedicated server" export).

## Installing

Every release carries the same five downloads plus `SHA256SUMS`:

| File | What it is |
|---|---|
| `boreal-bounce-<v>-linux-x86_64.tar.gz` | the game for Linux, a single binary |
| `boreal-bounce-<v>-windows-x86_64.zip` | the game for Windows |
| `boreal-bounce-<v>-web.zip` | the web build, unpack it into any web server |
| `boreal-bounce-<v>-dedicated-server-x86_64.tar.gz` | headless relay server for a VPS |
| `boreal-bounce-<v>-x86_64.flatpak` | Flatpak bundle for Linux desktops |

There is no macOS build yet. Every push and pull request builds the same set through
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
godot --headless --path . --export-release "Linux" dist/boreal_bounce.x86_64
flatpak-builder --force-clean --repo=repo build-flatpak packaging/flatpak/info.petrovs.BorealBounce.yml
flatpak build-bundle repo boreal-bounce.flatpak info.petrovs.BorealBounce
```
