#!/usr/bin/env bash
set -euo pipefail

echo "Starting Netlify Flutter build"
echo "Working directory: $(pwd)"

# Use preinstalled Flutter when available, otherwise install a local copy.
if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter not found in PATH. Installing local Flutter SDK..."
  FLUTTER_DIR="$HOME/flutter-sdk"
  if [ ! -d "$FLUTTER_DIR" ]; then
    git clone https://github.com/flutter/flutter.git -b stable --depth 1 "$FLUTTER_DIR"
  fi
  export PATH="$FLUTTER_DIR/bin:$PATH"
fi

echo "Flutter version:"
flutter --version

echo "Enable web platform"
flutter config --enable-web

echo "Fetching dependencies"
flutter pub get

echo "Building web release"
flutter build web --release

echo "Build complete"
