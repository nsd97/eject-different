#!/bin/bash
set -euo pipefail
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then echo "Run with sudo" >&2; exit 1; fi
launchctl unload /Library/LaunchDaemons/com.nsd97.eject-different.plist 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.nsd97.eject-different.plist
rm -rf /usr/local/libexec/eject-different
pmset -a disablesleep 0 sleep 1
echo "Eject Different removed; normal sleep restored."
