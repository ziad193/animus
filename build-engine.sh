#!/bin/zsh
# Builds Anki's engine plus our small bridge into engine/target/release/libstudy_engine.a
set -e
cd "$(dirname "$0")"
source "$HOME/.cargo/env"

export PROTOC="$PWD/tools/protoc/bin/protoc"
# Anki's build looks for this file in an old cargo folder layout; point it somewhere fixed.
export DESCRIPTORS_BIN="$PWD/engine/target/anki_descriptors.bin"
export MACOSX_DEPLOYMENT_TARGET=15.0
mkdir -p engine/target

cargo build --release --manifest-path engine/Cargo.toml
ls -lh engine/target/release/libstudy_engine.a
