#!/bin/zsh
# Builds "Animus Dev": a separate copy of Animus for trying out changes.
#
#   ./build-dev.sh           build and open Animus Dev
#   ./build-dev.sh --fresh   also re-copy your cards into its folder first
#   ./build-dev.sh --intel   run the Intel version instead (through Rosetta), to
#                            check it works on Intel Macs; the red strip says which
#
# It runs beside your real Animus without touching it:
#   - its own app identity (com.ziad.animus.dev), so both can be open at once
#   - its own data folder (~/Library/Application Support/Animus Dev), filled with
#     a copy of your cards; the real collection is only ever read, never written
#   - test-collection mode (separate settings and keychain item), never signed in
#     to AnkiWeb, and no update checks
set -e
cd "$(dirname "$0")"

FRESH=0; INTEL=0
for arg in "$@"; do
  case "$arg" in
    --fresh) FRESH=1 ;;
    --intel) INTEL=1 ;;
  esac
done

DEV_DATA="$HOME/Library/Application Support/Animus Dev"
REAL="$HOME/Library/Application Support/StudyApp"

# Your active profile's folder: a profile under Profiles/, or the original one.
real_profile_folder() {
  local id
  id=$(defaults read com.ziad.animus profiles.active 2>/dev/null || true)
  if [[ -n "$id" && "$id" != "default" && -d "$REAL/Profiles/$id" ]]; then
    echo "$REAL/Profiles/$id"
  else
    echo "$REAL"
  fi
}

if [[ $FRESH == 1 || ! -f "$DEV_DATA/collection.anki2" ]]; then
  SRC=$(real_profile_folder)
  echo "Copying cards from $SRC"
  mkdir -p "$DEV_DATA"
  rm -f "$DEV_DATA/collection.anki2" "$DEV_DATA/collection.anki2-wal" "$DEV_DATA/collection.anki2-shm"
  # A consistent snapshot, even while Animus has the collection open (read-only on the source).
  sqlite3 "file:$SRC/collection.anki2?mode=ro" ".backup '$DEV_DATA/collection.anki2'"
  # Pictures and sounds: APFS clones, so they take no extra space.
  if [[ -d "$SRC/collection.media" ]]; then
    rm -rf "$DEV_DATA/collection.media"
    cp -c -R "$SRC/collection.media" "$DEV_DATA/collection.media"
  fi
  # Background pictures, so they show without downloading.
  mkdir -p "$DEV_DATA/Backgrounds"
  for f in Resources/backgrounds/*.jpg; do
    [[ "$f" == *-thumb.jpg ]] || cp "$f" "$DEV_DATA/Backgrounds/"
  done
fi

if [[ $INTEL == 1 ]]; then ./build-app.sh --universal; else ./build-app.sh; fi

DEV="build/Animus Dev.app"
rm -rf "$DEV"
ditto build/Animus.app "$DEV"
PLIST="$DEV/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.ziad.animus.dev" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Animus Dev" "$PLIST"
/usr/libexec/PlistBuddy -c "Delete :CFBundleDisplayName" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Animus Dev" "$PLIST"
/usr/libexec/PlistBuddy -c "Delete :AnimusUpdateRepository" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :LSEnvironment" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSEnvironment:ITERUM_DATA_FOLDER string $DEV_DATA" "$PLIST"
# The red "DEV BUILD" strip, with the last published version beside this one.
git fetch -q --tags origin 2>/dev/null || true   # read-only: just learns the release tags
PREVIOUS=$(git tag --list 'v*' --sort=-v:refname | head -1 | sed 's/^v//')
/usr/libexec/PlistBuddy -c "Delete :AnimusDevBuild" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :AnimusDevBuild bool true" "$PLIST"
/usr/libexec/PlistBuddy -c "Delete :AnimusPreviousVersion" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :AnimusPreviousVersion string $PREVIOUS" "$PLIST"
# Its own icon, with a red DEV ribbon (make it with: swift scripts/make-dev-icon.swift).
[ -f Resources/AppIconDev.icns ] && cp Resources/AppIconDev.icns "$DEV/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$DEV" >/dev/null 2>&1 || true

# Restart it on the new build (your real Animus is left alone).
pkill -f "Animus Dev.app/Contents/MacOS/StudyApp" 2>/dev/null && sleep 2 || true
if [[ $INTEL == 1 ]]; then ARCH=(--arch x86_64); else ARCH=(); fi
open -g "${ARCH[@]}" "$DEV"
# A background launch can come up without its main window; asking again opens it.
sleep 4
open -g "${ARCH[@]}" "$DEV"
echo "Opened $DEV"
