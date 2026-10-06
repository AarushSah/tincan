#!/bin/sh
# Check formatting, build, and run every test that doesn't need this Mac's data. Exits
# non-zero on any formatting finding or failure.
#
#   ./scripts/check.sh            # formatting (scripts/lint.sh), build and tests
#   ./scripts/check.sh --live     # also the read-only checks against this Mac's Messages
#   ./scripts/check.sh --no-lint  # skip the formatting check
set -eu
cd "$(dirname "$0")/.."
. scripts/lib.sh

live=no
lint=yes
for argument in "$@"; do
  case "$argument" in
    --live) live=yes ;;
    --no-lint) lint=no ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "check.sh: unknown option $argument" >&2; exit 2 ;;
  esac
done

# First, because it takes seconds and a finding fails the check anyway.
if [ "$lint" = yes ]; then
  ./scripts/lint.sh
fi
relink_if_embedded_changed "$(swift build --show-bin-path)/tincan"
swift build
swift test --skip Live
if [ "$live" = yes ]; then
  TINCAN_LIVE_TESTS=1 swift test --filter Live
fi
echo "All checks passed."
