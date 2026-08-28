#!/bin/bash
set -euo pipefail
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run with sudo: sudo Scripts/install.sh" >&2
  exit 1
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release
BUILD="$ROOT/.build/arm64-apple-macosx/release"
DEST="/usr/local/libexec/eject-different"
mkdir -p "$DEST"
install -m 755 "$BUILD/eject-different" "$DEST/eject-different"
rm -rf "$DEST/EjectDifferent_EjectDifferent.bundle"
cp -R "$BUILD/EjectDifferent_EjectDifferent.bundle" "$DEST/"
chown -R root:wheel "$DEST"
cat > /Library/LaunchDaemons/com.nsd97.eject-different.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.nsd97.eject-different</string>
  <key>ProgramArguments</key><array><string>/usr/local/libexec/eject-different/eject-different</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>/var/log/eject-different.log</string>
  <key>StandardErrorPath</key><string>/var/log/eject-different.error.log</string>
  <key>ThrottleInterval</key><integer>5</integer>
</dict></plist>
PLIST
chmod 644 /Library/LaunchDaemons/com.nsd97.eject-different.plist
chown root:wheel /Library/LaunchDaemons/com.nsd97.eject-different.plist
plutil -lint /Library/LaunchDaemons/com.nsd97.eject-different.plist

# Closed-lid operation: intentionally keep this Mac awake on AC and battery.
pmset -a sleep 0 disablesleep 1

launchctl unload /Library/LaunchDaemons/com.nsd97.eject-different.plist 2>/dev/null || true
launchctl load -w /Library/LaunchDaemons/com.nsd97.eject-different.plist
echo "Installed. Think Different. Eject Different."
