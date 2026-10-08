#!/bin/bash
cd "$(dirname "$0")" || exit 1

echo ""
adb devices
echo "Installing SplineMaker.apk to first device"
adb install -r android/SplineMaker.apk
