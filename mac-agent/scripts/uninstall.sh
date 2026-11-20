#!/usr/bin/env bash
# Stop and remove the LaunchAgent and binary. Keeps config/state/logs unless --purge is given.
set -euo pipefail
LABEL="com.household.mac-agent"
SUPPORT="$HOME/Library/Application Support/HouseholdAgent"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$SUPPORT/bin"
echo "Removed LaunchAgent and binary."

if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "$SUPPORT" "$HOME/Library/Logs/HouseholdAgent"
  security delete-generic-password -s "$LABEL" -a agent_token >/dev/null 2>&1 || true
  echo "Purged config, state, outbox, logs and Keychain token."
else
  echo "Kept $SUPPORT (config, state.json, outbox.jsonl). Use --purge to remove."
fi
echo "Remember to remove the binary from Full Disk Access in System Settings if you are done with it."
