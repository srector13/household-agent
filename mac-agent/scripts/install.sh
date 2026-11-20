#!/usr/bin/env bash
# Build, sign and install the household mac-agent as a per-user LaunchAgent.
#
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   BRAIN_URL="http://brain.your-tailnet.ts.net:8080" \
#   HA_AGENT_TOKEN="<same token as brain security.agent_token>" \
#   ./scripts/install.sh
#
# SIGN_IDENTITY: run `security find-identity -v -p codesigning` to list yours. Signing with a stable
# Apple Developer identity is what keeps Full Disk Access / Reminders / Calendar grants across
# rebuilds. Without it the binary is ad-hoc signed and macOS may ask again after every rebuild.
set -euo pipefail

LABEL="com.household.mac-agent"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT="$HOME/Library/Application Support/HouseholdAgent"
BIN_DIR="$SUPPORT/bin"
LOG_DIR="$HOME/Library/Logs/HouseholdAgent"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG="$SUPPORT/config.json"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "install.sh must run on macOS" >&2
  exit 1
fi

echo "==> Building (release)"
cd "$HERE"
swift build -c release --product mac-agent
BUILT="$(swift build -c release --show-bin-path)/mac-agent"

mkdir -p "$BIN_DIR" "$LOG_DIR" "$HOME/Library/LaunchAgents"

# Stop a running copy before replacing the binary.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && sleep 1 || true

install -m 0755 "$BUILT" "$BIN_DIR/mac-agent"

echo "==> Signing"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp \
    --identifier "$LABEL" \
    --entitlements "$HERE/scripts/entitlements.plist" \
    -s "$SIGN_IDENTITY" "$BIN_DIR/mac-agent"
else
  echo "    SIGN_IDENTITY not set: ad-hoc signing. Privacy grants may need re-approval after each rebuild."
  codesign --force --options runtime --identifier "$LABEL" \
    --entitlements "$HERE/scripts/entitlements.plist" -s - "$BIN_DIR/mac-agent"
fi
codesign --verify --verbose=2 "$BIN_DIR/mac-agent"
"$BIN_DIR/mac-agent" --version

if [[ ! -f "$CONFIG" ]]; then
  echo "==> Writing default config to $CONFIG"
  cat > "$CONFIG" <<JSON
{
  "brain_url": "${BRAIN_URL:-http://brain.your-tailnet.ts.net:8080}",
  "keychain_service": "$LABEL",
  "keychain_account": "agent_token",
  "allow_handles": [],
  "labels": {},
  "context_count": 5,
  "log_level": "info"
}
JSON
  echo "    Edit it to set brain_url, labels and (optionally) allow_handles."
else
  echo "==> Keeping existing $CONFIG"
fi

if [[ -n "${HA_AGENT_TOKEN:-}" ]]; then
  echo "==> Storing agent token in the login Keychain"
  # -A is NOT used: only the signed agent (and `security`) gets access; macOS may ask once to allow it.
  security add-generic-password -U -s "$LABEL" -a agent_token -w "$HA_AGENT_TOKEN" \
    -T "$BIN_DIR/mac-agent" -T /usr/bin/security
fi

echo "==> Installing LaunchAgent"
sed "s#/Users/USERNAME#$HOME#g" "$HERE/launchd/$LABEL.plist" > "$PLIST_DST"
plutil -lint "$PLIST_DST" >/dev/null
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

cat <<MSG

Installed: $BIN_DIR/mac-agent
Logs:      $LOG_DIR/agent.log   (tail -f "$LOG_DIR/agent.log")

Next steps (one time):
  1. System Settings → Privacy & Security → Full Disk Access → "+" → press ⌘⇧G and paste:
       $BIN_DIR/mac-agent
     then enable it. (Needed to read ~/Library/Messages/chat.db.)
  2. Approve the Reminders and Calendar prompts the agent shows on start. If none appeared, check
     System Settings → Privacy & Security → Reminders / Calendars, or run:
       "$BIN_DIR/mac-agent" --request-permissions
  3. Restart the agent after granting Full Disk Access:
       launchctl kickstart -k gui/$(id -u)/$LABEL
  4. Check the brain dashboard health panel: heartbeat, fda_ok, reminders_ok, calendar_ok.
MSG
