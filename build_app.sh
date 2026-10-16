#!/bin/bash
# Builds SteadyTrain.app into ./build and signs it.
# Set SIGN_ID to a real signing identity (e.g. "Apple Development: you@...") to keep
# the Accessibility permission across rebuilds. Ad-hoc signing ("-") resets it each build.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/SteadyTrain.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/SteadyTrain "$APP/Contents/MacOS/SteadyTrain"
cp Info.plist "$APP/Contents/Info.plist"

codesign --force --sign "${SIGN_ID:--}" "$APP"

echo "Built $APP"
echo "Run it with: open $APP"
