#!/bin/zsh
# Builds Iterum.app into ./build (run ./build-engine.sh first, or after updating Anki).
set -e
cd "$(dirname "$0")"

[ -f engine/target/release/libstudy_engine.a ] || ./build-engine.sh
swift build -c release

APP="build/Iterum.app"
rm -rf "$APP" build/Study.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/StudyApp "$APP/Contents/MacOS/StudyApp"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Maths formulas on cards (MathJax, Apache licence). Loaded only for cards that use it.
cp -R Resources/mathjax "$APP/Contents/Resources/mathjax"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP ($(du -sh "$APP" | cut -f1))"
