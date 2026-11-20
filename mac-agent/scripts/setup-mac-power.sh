#!/usr/bin/env bash
# Phase 6: keep the Mac hub awake 24/7 (including lid-closed on power) so the agent never misses
# messages. Run once with an admin account. Undo with:  sudo pmset -a disablesleep 0; sudo pmset restoredefaults
set -euo pipefail

if [[ "$(uname)" != "Darwin" ]]; then
  echo "macOS only" >&2
  exit 1
fi

echo "==> Disabling system and disk sleep"
sudo pmset -a sleep 0 disksleep 0
# Display may sleep; that does not affect the agent.
sudo pmset -a displaysleep 10
# Lid-closed operation without an external display (Apple silicon laptops).
sudo pmset -a disablesleep 1
# Come back after a power failure and keep network alive.
sudo pmset -a autorestart 1 2>/dev/null || true
sudo pmset -a womp 1 2>/dev/null || true
sudo pmset -a tcpkeepalive 1 2>/dev/null || true

echo
pmset -g | sed 's/^/    /'

cat <<'MSG'

Manual steps that cannot be scripted safely:

  • Battery health (MacBook kept on power 24/7):
      macOS 15+: System Settings → Battery → (i) next to Battery Health → "Optimized Battery Charging"
      and, where offered, the 80% charge limit. On older versions use a charge-limit tool
      (e.g. AlDente or `bclm`) to hold the battery around 50–80%.
  • Automatic login so the LaunchAgent starts after a reboot (it runs in the GUI session):
      System Settings → Users & Groups → "Automatically log in as…" (requires FileVault off), OR
      leave FileVault on and accept that someone must log in once after each reboot —
      the brain will send a "Mac agent offline" alert in that case.
  • System Settings → Energy (or Battery → Options): enable "Prevent automatic sleeping when the
    display is off" and "Wake for network access".
  • Software updates: System Settings → General → Software Update → Automatic Updates → disable
    "Install macOS updates" automatically (avoid surprise reboots), keep security responses on.

Verify: close the lid on power, wait 10 minutes, and confirm heartbeats on the brain dashboard.
MSG
