#!/bin/bash
set -euo pipefail
# Node release archive checksums from https://nodejs.org/dist/v24.8.0/SHASUMS256.txt
root=$(cd "$(dirname "$0")/.." && pwd)
destination=${1:?usage: package-usage-helper.sh destination [arm64|x86_64]}
arch=${2:-$(uname -m)}
case "$arch" in
  arm64) nodearch=arm64; sha=d81191a1866760eb918caa976c023036bc1fc7405ea31b148905211522045767 ;;
  x86_64) nodearch=x64; sha=6fd8496b59baa8f86a24e3eb03308b763091716ffc6b6e1094d1a5e5696dd6dd ;;
  *) echo 'Unsupported usage runtime architecture' >&2; exit 1 ;;
esac
cache="$root/build/usage-runtime"
name="node-v24.8.0-darwin-$nodearch"
archive="$cache/$name.tar.gz"
mkdir -p "$cache"
if ! echo "$sha  $archive" | shasum -a 256 -c - >/dev/null 2>&1; then
  curl --fail --location --silent --show-error --max-time 600 "https://nodejs.org/dist/v24.8.0/$name.tar.gz" -o "$archive.download"
  echo "$sha  $archive.download" | shasum -a 256 -c -
  mv "$archive.download" "$archive"
fi
# Verify even when the cache is warm, before extracting/executing anything.
echo "$sha  $archive" | shasum -a 256 -c -
tar -xzf "$archive" -C "$cache"
mkdir -p "$destination/runtime/$arch"
cp "$cache/$name/bin/node" "$destination/runtime/$arch/node"
cp "$cache/$name/LICENSE" "$destination/runtime/$arch/LICENSE"
cp -R "$root/UsageHelper/host" "$root/UsageHelper/vendor" "$destination/"
cp "$root/UsageHelper/main.mjs" "$destination/"
# No provider code or credential access at build time.
if [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --entitlements "$root/UsageHelper/runtime.entitlements" "$destination/runtime/$arch/node"
fi
