#!/bin/zsh
# Builds Anki's engine plus our small bridge into engine/target/lib/libstudy_engine.a
#   ./build-engine.sh             Apple Silicon only (quick, for development)
#   ./build-engine.sh --universal Apple Silicon + Intel (for releases)
set -e
cd "$(dirname "$0")"
source "$HOME/.cargo/env"

export PROTOC="$PWD/tools/protoc/bin/protoc"
# Anki's build looks for this file in an old cargo folder layout; point it somewhere fixed.
export DESCRIPTORS_BIN="$PWD/engine/target/anki_descriptors.bin"
export MACOSX_DEPLOYMENT_TARGET=15.0
mkdir -p engine/target/lib

cargo build --release --manifest-path engine/Cargo.toml
if [[ "$1" == "--universal" ]]; then
  cargo build --release --manifest-path engine/Cargo.toml --target x86_64-apple-darwin
  lipo -create engine/target/release/libstudy_engine.a \
               engine/target/x86_64-apple-darwin/release/libstudy_engine.a \
       -output engine/target/lib/libstudy_engine.a
else
  cp engine/target/release/libstudy_engine.a engine/target/lib/libstudy_engine.a
fi
ls -lh engine/target/lib/libstudy_engine.a
lipo -archs engine/target/lib/libstudy_engine.a
