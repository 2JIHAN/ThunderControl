#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REV='487f196f7f561d5ee08cee968d1d4b4dd24d365f'
if [[ ! -e Pairing/BoringSSL/.git ]]; then
  git submodule update --init --recursive -- Pairing/BoringSSL
fi
ACTUAL="$(git -C Pairing/BoringSSL rev-parse HEAD)"
if [[ "$ACTUAL" != "$REV" ]]; then
  echo 'BoringSSL revision does not match the pinned revision.' >&2
  exit 1
fi
command -v cmake >/dev/null || { echo 'CMake is required; install it and add it to PATH.' >&2; exit 1; }
BUILD="$ROOT/own_tmp/boringssl"
MAP="-ffile-prefix-map=\"$ROOT=.\" -fdebug-prefix-map=\"$ROOT=.\""
cmake -S Pairing/BoringSSL -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DBUILD_TESTING=OFF -DFIPS=OFF \
  "-DCMAKE_C_FLAGS=$MAP" "-DCMAKE_CXX_FLAGS=$MAP" "-DCMAKE_ASM_FLAGS=$MAP"
cmake --build "$BUILD" --target crypto --parallel "${BUILD_JOBS:-4}"
mkdir -p Pairing/lib
cp "$BUILD/libcrypto.a" Pairing/lib/libcrypto.a
