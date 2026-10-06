# Shared by check.sh, install.sh and release.sh, which source it from the repository root
# with `set -eu`. Not meant to run on its own. Variables inside functions start with lib_ so
# they can't overwrite the caller's.

tincan_identifier="io.github.aarushsah.tincan"
tincan_entitlements="Support/tincan.entitlements"

# The linker embeds Support/Info.plist, Support/PhoneNumberMetadata.json and the skill's
# files (skills/tincan) in tincan, but SwiftPM relinks only when code changes. When one of
# them is newer than the binary, remove every linked tincan, each architecture's included, so
# the next build links them again.
#   relink_if_embedded_changed <binary>
relink_if_embedded_changed() {
  if [ -e "$1" ] && [ -n "$(find Support/Info.plist Support/PhoneNumberMetadata.json skills -type f -newer "$1" | head -n 1)" ]; then
    run find .build -type f -name tincan -perm -u+x -exec rm -f {} +
  fi
}

# Runs a command, or with dry_run=yes prints it instead.
run() {
  if [ "${dry_run:-no}" = yes ]; then
    printf '+'
    for lib_word in "$@"; do printf ' %s' "$(quote "$lib_word")"; done
    printf '\n'
  else
    "$@"
  fi
}

# Like run, writing the command's standard output to the file named first.
run_to() {
  lib_output="$1"
  shift
  if [ "${dry_run:-no}" = yes ]; then
    run "$@"
    printf '  > %s\n' "$(quote "$lib_output")"
  else
    "$@" > "$lib_output"
  fi
}

quote() {
  case "$1" in
    '' | *[!A-Za-z0-9_./:=@%+,-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Prints the SHA-1 of the first valid code-signing identity in the keychain whose name
# starts with one of the given kinds, in order, or nothing.
find_signing_identity() {
  lib_identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  for lib_kind in "$@"; do
    lib_candidate="$(printf '%s\n' "$lib_identities" | grep "\"$lib_kind" | head -1 | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-F]{40}).*/\1/')"
    if [ -n "$lib_candidate" ]; then
      printf '%s\n' "$lib_candidate"
      return 0
    fi
  done
}

# Signs a binary as tincan, with the hardened runtime and the Apple Events entitlement.
#   sign_tincan <binary> <identity or -> [codesign options…]
sign_tincan() {
  lib_binary="$1"
  lib_identity="$2"
  shift 2
  run codesign --force --sign "$lib_identity" --identifier "$tincan_identifier" --options runtime "$@" \
    --entitlements "$tincan_entitlements" "$lib_binary"
}

# Succeeds when the binary is signed with the hardened runtime, so DYLD_ variables can't
# load code into it.
has_hardened_runtime() {
  codesign --display --verbose "$1" 2>&1 | grep -q '^CodeDirectory.*flags=.*runtime'
}

# Writes tincan's man page and shell completions, generated from a built tincan, into a
# directory laid out like an install prefix:
#
#   share/man/man1/tincan.1
#   share/zsh/site-functions/_tincan
#   share/bash-completion/completions/tincan
#   share/fish/vendor_completions.d/tincan.fish
#
#   generate_extras <tincan binary> <directory> <debug|release>
#
# The man page comes from swift-argument-parser's generate-manual tool, built from the
# package's dependency, and is dated by the last commit so rebuilds don't change it.
generate_extras() {
  lib_binary="$1"
  lib_directory="$2"
  lib_configuration="$3"
  run swift build -q -c "$lib_configuration" --product generate-manual || return 1
  lib_tools="$(swift build -c "$lib_configuration" --show-bin-path)" || return 1
  run mkdir -p "$lib_directory/share/man/man1" "$lib_directory/share/zsh/site-functions" \
    "$lib_directory/share/bash-completion/completions" "$lib_directory/share/fish/vendor_completions.d" || return 1
  lib_date="$(git log -1 --format=%cs 2>/dev/null || true)"
  run "$lib_tools/generate-manual" "$lib_binary" --output-directory "$lib_directory/share/man/man1" \
    ${lib_date:+--date "$lib_date"} || return 1
  run_to "$lib_directory/share/zsh/site-functions/_tincan" "$lib_binary" --generate-completion-script zsh || return 1
  run_to "$lib_directory/share/bash-completion/completions/tincan" "$lib_binary" --generate-completion-script bash || return 1
  run_to "$lib_directory/share/fish/vendor_completions.d/tincan.fish" "$lib_binary" --generate-completion-script fish || return 1
}

# Prints a path with the home directory as ~.
display_path() {
  case "$1" in
    "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
    *) printf '%s' "$1" ;;
  esac
}
