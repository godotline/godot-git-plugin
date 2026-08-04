#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
godot_bin="${GODOT_BIN:-/home/meny/Code/Godot}"

if [[ ! -x "$godot_bin" ]] && command -v godot >/dev/null 2>&1; then
	godot_bin="$(command -v godot)"
fi

if [[ ! -x "$godot_bin" ]]; then
	printf 'Godot executable not found: %s\n' "$godot_bin" >&2
	exit 127
fi

exec "$godot_bin" --headless --path "$repo_root/tests/godot_harness" --script res://run_tests.gd -- "$@"
