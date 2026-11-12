#!/usr/bin/env bash
# Regenerates BowKit/Sources/GrimmoryAPI/Generated from the vendored Grimmory spec.
# Output is committed, so Xcode never builds, runs or has to trust the generator.
set -euo pipefail

GENERATOR_VERSION="1.14.4"

root="$(cd "$(dirname "$0")/.." && pwd)"
target="$root/BowKit/Sources/GrimmoryAPI"
tools="$root/.build-tools"
generator="$tools/swift-openapi-generator-$GENERATOR_VERSION"

python3 -I "$root/Scripts/patch-grimmory-openapi.py"

if [[ ! -d "$generator" ]]; then
  mkdir -p "$tools"
  git clone --quiet --depth 1 --branch "$GENERATOR_VERSION" \
    https://github.com/apple/swift-openapi-generator.git "$generator"
fi

rm -rf "$target/Generated"
swift run --quiet --package-path "$generator" -c release swift-openapi-generator generate \
  "$target/openapi.json" \
  --config "$target/openapi-generator-config.yaml" \
  --output-directory "$target/Generated"
