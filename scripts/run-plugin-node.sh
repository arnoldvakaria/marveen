#!/bin/bash
# Runs a Claude plugin's server.ts via Node.js instead of bun.
# Used on macOS < 13.0 where bun/esbuild require newer OS symbols.
# $1 = plugin root (Claude Code expands ${CLAUDE_PLUGIN_ROOT})
PLUGIN_ROOT="$1"
cd "$PLUGIN_ROOT"
[ -d node_modules ] || npm install --silent --no-fund 1>&2
exec node --experimental-strip-types server.ts
