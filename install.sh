#!/bin/bash
# Install this checkout as an Omarchy shell plugin and grant device access.
#
#   ./install.sh            copy the plugin, enable it, install the udev rule
#   ./install.sh --no-udev  skip the udev rule (needs root)
#
# Omarchy refuses symlinks inside a plugin folder, so the files are copied;
# re-run after editing. The shell hot-reloads the plugin when files change.
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$here/manifest.json")"
dest="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$id"

omarchy-plugin-validate "$here"

mkdir -p "$dest"
rsync -a --delete --exclude .git --exclude install.sh "$here/" "$dest/"
echo "installed to $dest"

if omarchy-shell -q shell ping >/dev/null 2>&1; then
  omarchy-shell shell rescanPlugins >/dev/null
  if ! omarchy plugin list --json 2>/dev/null | python3 -c '
import json, sys
plugins = json.load(sys.stdin)
items = plugins if isinstance(plugins, list) else plugins.get("plugins", [])
sys.exit(0 if any(p.get("id") == sys.argv[1] and p.get("enabled") for p in items) else 1)
' "$id"; then
    omarchy plugin enable "$id" >/dev/null && echo "enabled $id in the bar"
  fi
else
  echo "omarchy-shell is not running; enable later with: omarchy plugin enable $id"
fi

if [[ ${1:-} != --no-udev ]]; then
  if [[ -f /etc/udev/rules.d/70-ulanzi-vibekey.rules ]] && cmp -s "$here/udev/70-ulanzi-vibekey.rules" /etc/udev/rules.d/70-ulanzi-vibekey.rules; then
    echo "udev rule already installed"
  else
    "$dest/bin/vibekey-install-access" && echo "udev rule installed"
  fi
fi
