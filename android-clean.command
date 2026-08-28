#!/bin/bash
cd "$(dirname "$0")" || exit 1

echo ""
echo "Cleaning Gradle build output and .DS_Store files in: $(pwd)"
rm -rf android/build/build && find android -name .DS_Store -delete
echo "Completed"
