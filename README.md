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
