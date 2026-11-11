#!/bin/zsh
# Builds Animus.app into ./build.
#   ./build-app.sh             Apple Silicon only (quick, for development)
#   ./build-app.sh --universal Apple Silicon + Intel, for sharing with others
set -e
cd "$(dirname "$0")"

# Rebuild the engine first if its Rust code has changed since it was last built.
LIB=engine/target/lib/libstudy_engine.a
if [[ -f $LIB && -n "$(find engine/src engine/Cargo.toml -newer $LIB -type f -print -quit)" ]]; then
  if lipo -archs $LIB | grep -q x86_64 || [[ "$1" == "--universal" ]]; then ./build-engine.sh --universal; else ./build-engine.sh; fi
fi

if [[ "$1" == "--universal" ]]; then
  # The engine has to contain both kinds of Mac too.
  if ! lipo -archs engine/target/lib/libstudy_engine.a 2>/dev/null | grep -q x86_64; then
    ./build-engine.sh --universal
  fi
  # Newer Swift puts both kinds of Mac in the same folder, one overwriting the
  # other, so ask where each build went and keep a copy before the next one.
  mkdir -p .build/universal
  for ARCH in arm64 x86_64; do
    swift build -c release --triple $ARCH-apple-macosx15.0
    BUILT="$(swift build -c release --triple $ARCH-apple-macosx15.0 --show-bin-path)/StudyApp"
    if [[ "$(lipo -archs "$BUILT")" != "$ARCH" ]]; then
      echo "Stopped: expected an $ARCH build at $BUILT, found $(lipo -archs "$BUILT")." >&2
      exit 1
    fi
    cp "$BUILT" .build/universal/StudyApp-$ARCH
    cp "${BUILT:h}/animus-connector" .build/universal/animus-connector-$ARCH
  done
  lipo -create .build/universal/StudyApp-arm64 .build/universal/StudyApp-x86_64 \
       -output .build/universal/StudyApp
  lipo -create .build/universal/animus-connector-arm64 .build/universal/animus-connector-x86_64 \
       -output .build/universal/animus-connector
  BINARY=.build/universal/StudyApp
else
  [ -f engine/target/lib/libstudy_engine.a ] || ./build-engine.sh
  # A universal build leaves .build/release pointing at another folder; let Swift remake it.
  [ -L .build/release ] && rm .build/release
  swift build -c release
  BINARY=.build/release/StudyApp
fi

# Never package an out-of-date build: the app must be newer than every source file.
# (Each program is checked against its own sources: changing only the helper doesn't rebuild the app.)
STALE="$(find Sources/StudyApp Sources/StudyCore Sources/CStudyEngine Package.swift -newer "$BINARY" -type f -print -quit)"
if [[ -n "$STALE" ]]; then
  echo "Stopped: $BINARY is older than $STALE, so it doesn't contain your latest changes." >&2
  exit 1
fi
STALE="$(find Sources/AnimusConnector Package.swift -newer "${BINARY:h}/animus-connector" -type f -print -quit)"
if [[ -n "$STALE" ]]; then
  echo "Stopped: the Claude helper is older than $STALE, so it doesn't contain your latest changes." >&2
  exit 1
fi

APP="build/Animus.app"
rm -rf "$APP" build/Study.app build/Iterum.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/StudyApp"
# The helper the Claude app starts to reach Animus (test only; see Connector.swift).
cp "${BINARY:h}/animus-connector" "$APP/Contents/MacOS/animus-connector"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Maths formulas on cards (MathJax, Apache licence). Loaded only for cards that use it.
cp -R Resources/mathjax "$APP/Contents/Resources/mathjax"
# Shown in About Animus.
cp Resources/Credits.html "$APP/Contents/Resources/Credits.html"
# Background previews only: the full pictures download when picked (see Backgrounds.swift).
# Public-domain paintings (The Met, CC0) and a NASA photo. See Credits.html.
mkdir -p "$APP/Contents/Resources/backgrounds"
cp Resources/backgrounds/*-thumb.jpg "$APP/Contents/Resources/backgrounds/"
codesign --force --sign - "$APP/Contents/MacOS/animus-connector" >/dev/null 2>&1 || true
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP ($(du -sh "$APP" | cut -f1), $(lipo -archs "$APP/Contents/MacOS/StudyApp"))"
