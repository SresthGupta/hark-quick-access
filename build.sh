#!/bin/bash
# Builds and launches Hark Quick Access into ~/Applications. Needs Xcode command line tools.
set -e
cd "$(dirname "$0")"
A="$HOME/Applications/Hark Quick Access.app"
mkdir -p "$A/Contents/MacOS"
pkill -x HarkQuickAccess || true
swiftc -O main.swift -o "$A/Contents/MacOS/HarkQuickAccess" -framework Cocoa -framework WebKit -framework Carbon
cp Info.plist "$A/Contents/"
codesign --force -s - "$A"
open "$A"
echo "Installed to $A"
