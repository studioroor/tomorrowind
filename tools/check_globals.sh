#!/bin/bash
# Flags reads/writes of unexpected globals (usually a typo or a local
# function used before its definition). Usage: tools/check_globals.sh
cd "$(dirname "$0")/.."
ALLOWED='^(require|print|pairs|ipairs|next|type|tostring|tonumber|pcall|xpcall|error|assert|select|unpack|setmetatable|getmetatable|rawget|rawset|math|string|table|os|debug|io|package|_G|test|eq|near)$'
status=0
for f in $(find scripts tests -name '*.lua'); do
  bad=$(luajit -bl "$f" 2>&1 | grep -oE 'G(GET|SET) .*"[A-Za-z_][A-Za-z0-9_]*"' | grep -oE '"[^"]+"$' | tr -d '"' | sort -u | grep -vE "$ALLOWED")
  if [ -n "$bad" ]; then echo "$f: unexpected globals: $(echo $bad)"; status=1; fi
done
[ $status -eq 0 ] && echo "globals ok"
exit $status
