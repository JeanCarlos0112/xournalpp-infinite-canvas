#!/bin/sh
# Runs every test with Lua 5.4: sh tests/run_all.sh
cd "$(dirname "$0")" || exit 1
status=0
for t in test_*.lua; do
  if lua5.4 "$t" >/dev/null 2>&1; then echo "ok    $t"; else echo "FAIL  $t"; status=1; fi
done
exit $status
