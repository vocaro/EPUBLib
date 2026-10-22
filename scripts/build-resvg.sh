#!/usr/bin/env bash
# Rebuild the vendored, static Apple renderer; package consumers do not need Rust.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=${EPUBLIB_RESVG_BUILD_DIR:-"$root/.build/resvg"}
output=${EPUBLIB_RESVG_OUTPUT:-"$root/Vendor/Resvg/Resvg.xcframework"}
commit=68b14c4c3bccdb60344c777406486b54c36ec1a4 # resvg 0.48.1
checksum=fda0203e2dc383ea334c2d95a9af83526d32647e63d8dee43c2875e95c641c0c
mkdir -p "$work"
curl --fail --location --retry 3 "https://codeload.github.com/linebender/resvg/tar.gz/$commit" -o "$work/source.tar.gz"
echo "$checksum  $work/source.tar.gz" | shasum -a 256 -c -
mkdir -p "$work/source"
tar -xzf "$work/source.tar.gz" --strip-components=1 -C "$work/source"
# Pin the one dependency cleanup guard needed for panic unwinding. A path patch
# keeps Cargo's registry cache untouched and makes the exact changed source reviewable.
tiny_skia_checksum=47ffee5eaaf5527f630fb0e356b90ebdec84d5d18d937c5e440350f88c5a91ea
curl --fail --location --retry 3 "https://static.crates.io/crates/tiny-skia/tiny-skia-0.12.0.crate" -o "$work/tiny-skia.crate"
echo "$tiny_skia_checksum  $work/tiny-skia.crate" | shasum -a 256 -c -
mkdir -p "$work/source/vendor/tiny-skia"
tar -xzf "$work/tiny-skia.crate" --strip-components=1 -C "$work/source/vendor/tiny-skia"
python3 "$root/scripts/patch-resvg.py" "$work/source"

# Use an isolated toolchain. No changes to the developer's global Rust installation.
export CARGO_HOME="$work/cargo" RUSTUP_HOME="$work/rustup"
if [[ ! -x "$CARGO_HOME/bin/rustup" ]]; then
    curl --fail --location --retry 3 "https://static.rust-lang.org/rustup/dist/$(uname -m | sed 's/arm64/aarch64/')-apple-darwin/rustup-init" -o "$work/rustup-init"
    chmod +x "$work/rustup-init"
    "$work/rustup-init" -y --no-modify-path --profile minimal --default-toolchain 1.95.0
fi
export PATH="$CARGO_HOME/bin:$PATH"
rustup toolchain install 1.95.0 --profile minimal
# The standard library is built from its own 1.95.0 source without its `backtrace` feature,
# whose symbolizer reads the executable with `fstat`: an API that an app has to declare in its
# privacy manifest (#685). Unwinding stays, for the panic boundary. `-Zbuild-std` is unstable,
# and RUSTC_BOOTSTRAP lets the pinned stable compiler use it.
rustup component add --toolchain 1.95.0 rust-src
export CARGO_TARGET_DIR="$work/target"
for target in aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
    RUSTC_BOOTSTRAP=1 cargo +1.95.0 build --manifest-path "$work/source/Cargo.toml" --locked --package resvg-capi --profile production --no-default-features --features text,raster-images --target "$target" \
        -Zbuild-std=std,panic_unwind -Zbuild-std-features=panic-unwind
done
mkdir -p "$work/headers" "$work/mac" "$work/ios" "$work/simulator"
cp "$work/source/crates/c-api/resvg.h" "$work/headers/"
printf 'module CResvg { header "resvg.h" export * }\n' > "$work/headers/module.modulemap"
lipo -create "$work/target/aarch64-apple-darwin/production/libresvg.a" "$work/target/x86_64-apple-darwin/production/libresvg.a" -output "$work/mac/libresvg.a"
cp "$work/target/aarch64-apple-ios/production/libresvg.a" "$work/ios/libresvg.a"
lipo -create "$work/target/aarch64-apple-ios-sim/production/libresvg.a" "$work/target/x86_64-apple-ios/production/libresvg.a" -output "$work/simulator/libresvg.a"
if [[ -e "$output" ]]; then mv "$output" "$work/previous.xcframework.$(date +%s)"; fi
xcodebuild -create-xcframework -library "$work/mac/libresvg.a" -headers "$work/headers" -library "$work/ios/libresvg.a" -headers "$work/headers" -library "$work/simulator/libresvg.a" -headers "$work/headers" -output "$output"
shasum -a 256 "$output"/*/libresvg.a
cargo +1.95.0 metadata --manifest-path "$work/source/Cargo.toml" --locked --format-version 1 --filter-platform aarch64-apple-darwin --no-default-features --features resvg-capi/text,resvg-capi/raster-images > "$work/metadata.json"
rust_docs="$RUSTUP_HOME/toolchains/1.95.0-$(rustc +1.95.0 -vV | sed -n 's/host: //p')/share/doc/rust"
python3 "$root/scripts/resvg-notices.py" "$work/metadata.json" "$work/source" "$rust_docs" "$(dirname "$output")"
