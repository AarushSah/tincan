#!/bin/sh
# Check Swift formatting with `swift format lint` and the repository's .swift-format.
# Fails on any finding.
#
#   ./scripts/lint.sh                  # Sources, Tests and Package.swift
#   ./scripts/lint.sh <file or dir>…   # only these
#
# `swift format --in-place --recursive <file or dir>…` fixes most findings. check.sh runs
# this first unless you pass --no-lint.
set -eu
cd "$(dirname "$0")/.."

for argument in "$@"; do
  case "$argument" in
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "lint.sh: unknown option $argument" >&2; exit 2 ;;
  esac
  # swift format skips a path that doesn't exist without saying so.
  [ -e "$argument" ] || { echo "lint.sh: $argument doesn't exist." >&2; exit 2; }
done
[ "$#" -gt 0 ] || set -- Sources Tests Package.swift

findings="$(mktemp "${TMPDIR:-/tmp}/tincan-lint.XXXXXX")"
trap 'rm -f "$findings"' EXIT
status=0
swift format lint --configuration .swift-format --recursive --parallel "$@" 2> "$findings" || status=$?
cat "$findings" >&2
count="$(grep -cE ': (warning|error): ' "$findings" || true)"

if [ "$count" -gt 0 ]; then
  if [ "$count" -eq 1 ]; then findings_noun="1 finding"; else findings_noun="$count findings"; fi
  echo "Formatting: $findings_noun. \`swift format --in-place --recursive $*\` fixes most of them." >&2
  exit 1
fi
if [ "$status" -ne 0 ]; then
  echo "lint.sh: swift format lint failed." >&2
  exit "$status"
fi
echo "Formatting: no findings."
