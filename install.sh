#!/bin/bash
# Installs (or updates) Claude Usage from the latest GitHub release:
#   curl -fsSL https://raw.githubusercontent.com/wilsongrchan/claude-usage-widget/main/install.sh | bash
# It downloads the same ClaudeUsage.zip as the Download link, copies the app to
# /Applications (or ~/Applications if that isn't writable) and opens it. No sudo.
set -euo pipefail

URL="https://github.com/wilsongrchan/claude-usage-widget/releases/latest/download/ClaudeUsage.zip"
APP_NAME="ClaudeUsage.app"

say() { printf '%s\n' "$*"; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Claude Usage is a Mac app."
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 26 )) || fail "Claude Usage needs macOS 26 or later (this Mac has $(sw_vers -productVersion))."

tmp="$(mktemp -d "${TMPDIR:-/tmp}/claude-usage.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

say "Downloading the latest Claude Usage…"
curl -fL --progress-bar -o "$tmp/ClaudeUsage.zip" "$URL" || fail "Download failed."
ditto -x -k "$tmp/ClaudeUsage.zip" "$tmp/unzipped" || fail "Couldn't unpack the download."
src="$(find "$tmp/unzipped" -maxdepth 3 -type d -name "$APP_NAME" -print -quit)"
[[ -n "$src" ]] || fail "The download didn't contain $APP_NAME."

if [[ -w /Applications ]]; then
  dest_dir="/Applications"
else
  dest_dir="$HOME/Applications"
  mkdir -p "$dest_dir"
fi
dest="$dest_dir/$APP_NAME"

if pgrep -x ClaudeUsage >/dev/null; then
  say "Quitting the running copy…"
  pkill -x ClaudeUsage || true
  for _ in {1..20}; do pgrep -x ClaudeUsage >/dev/null || break; sleep 0.25; done
fi

rm -rf "$dest"
ditto "$src" "$dest"
say "Installed to $dest"

open "$dest"
say "Claude Usage is starting. Look for it on your desktop and in the menu bar."
