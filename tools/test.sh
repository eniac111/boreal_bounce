#!/bin/sh
# Import (refreshes the class cache for new class_name scripts) then run the test suite.
cd "$(dirname "$0")/.." || exit 1
godot --headless --path . --import >/dev/null 2>&1
out=$(godot --headless --path . -s tests/run_tests.gd "$@" 2>&1)
status=$?
printf '%s\n' "$out"
if printf '%s' "$out" | grep -q "SCRIPT ERROR"; then
	echo "script errors present"
	exit 1
fi
exit $status
