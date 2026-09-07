#!/bin/sh
# Render the game to a PNG without touching the desktop: runs Godot under a virtual X server
# (Xvfb, software OpenGL). Usage:
#   tools/shot.sh OUT.png [--frames=N] [--scene=game|menu|intro|options|keys|scores]
#                        [--seed=S] [--level=L] [--autoplay] [--pause-at=N]
# See src/debug/screenshot.gd for the arguments.
cd "$(dirname "$0")/.." || exit 1
out=$1; shift
# SHOT_RES=WxH renders in a window of that size (default 1280x960).
res=${SHOT_RES:-1280x960}
exec timeout 120 xvfb-run -a -s "-screen 0 ${res}x24" \
	godot --path . --display-driver x11 --rendering-driver opengl3 --resolution "$res" -- --screenshot="$out" "$@" 2>&1 \
	| grep -E 'SCRIPT ERROR|ERROR|screenshot|at:' | grep -vE 'still in use|ObjectDB'
