#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:?usage: build_microphone_driver.sh <output-directory> [local|distribution]}"
SIGNING_MODE="${2:-local}"
DRIVER="${OUTPUT}/RcHarnessMicrophone.driver"
mkdir -p "${DRIVER}/Contents/MacOS"
install -m 644 "${ROOT}/Drivers/RcHarnessMicrophone/Info.plist" "${DRIVER}/Contents/Info.plist"
BUILD_DIR="$(mktemp -d "${OUTPUT}/.rcharness-driver.XXXXXX")"
trap 'rm -rf "${BUILD_DIR}"' EXIT

for ARCH in arm64 x86_64; do
  xcrun clang -arch "${ARCH}" -std=c11 -O2 -Wall -Wextra -Wno-unused-parameter -Werror \
    -mmacosx-version-min=14.0 -bundle -fvisibility=hidden \
    -framework CoreAudio -framework CoreFoundation \
    "${ROOT}/Drivers/RcHarnessMicrophone/Driver.c" \
    -o "${BUILD_DIR}/RcHarnessMicrophone-${ARCH}"
done

lipo -create \
  "${BUILD_DIR}/RcHarnessMicrophone-arm64" \
  "${BUILD_DIR}/RcHarnessMicrophone-x86_64" \
  -output "${DRIVER}/Contents/MacOS/RcHarnessMicrophone"
"${ROOT}/scripts/sign_macos_code.sh" "${DRIVER}" vip.tokenzz.rcharness.microphone "${SIGNING_MODE}"
