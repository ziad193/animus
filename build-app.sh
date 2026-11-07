#!/bin/zsh
# Builds Animus.app into ./build.
#   ./build-app.sh             Apple Silicon only (quick, for development)
#   ./build-app.sh --universal Apple Silicon + Intel, for sharing with others
set -e
cd "$(dirname "$0")"

if [[ "$1" == "--universal" ]]; then
  # The engine has to contain both kinds of Mac too.
  if ! lipo -archs engine/target/lib/libstudy_engine.a 2>/dev/null | grep -q x86_64; then
    ./build-engine.sh --universal
  fi
  swift build -c release --triple arm64-apple-macosx15.0
  swift build -c release --triple x86_64-apple-macosx15.0
  mkdir -p .build/universal
  lipo -create .build/arm64-apple-macosx/release/StudyApp .build/x86_64-apple-macosx/release/StudyApp \
       -output .build/universal/StudyApp
  BINARY=.build/universal/StudyApp
else
  [ -f engine/target/lib/libstudy_engine.a ] || ./build-engine.sh
  # A universal build leaves .build/release pointing at another folder; let Swift remake it.
  [ -L .build/release ] && rm .build/release
  swift build -c release
  BINARY=.build/release/StudyApp
fi

APP="build/Animus.app"
rm -rf "$APP" build/Study.app build/Iterum.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/StudyApp"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Maths formulas on cards (MathJax, Apache licence). Loaded only for cards that use it.
cp -R Resources/mathjax "$APP/Contents/Resources/mathjax"
# Shown in About Animus.
cp Resources/Credits.html "$APP/Contents/Resources/Credits.html"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP ($(du -sh "$APP" | cut -f1), $(lipo -archs "$APP/Contents/MacOS/StudyApp"))"
