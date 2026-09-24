#!/bin/bash
# build.sh [abi]: the harness (libsurfprobe.so, classes.dex) into out/<abi>/,
# against the mpv headers of buildscripts/deps/mpv and the libmpv.so of
# buildscripts/prefix/<abi> (link time only: run.sh pushes whichever
# libmpv.so is tested). abi: arm64-v8a (default) | x86_64.
# Needs the NDK include/depinfo.sh pins (buildscripts/sdk/.../ndk/$v_ndk) and
# an Android SDK with platforms/android-34 and build-tools 35 (ANDROID_HOME,
# or ~/Library/Android/sdk).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
bs=$here/../../buildscripts
abi=${1:-arm64-v8a}
. "$bs/include/depinfo.sh"
ndk=$bs/sdk/android-sdk-linux/ndk/$v_ndk
case $abi in
  arm64-v8a) cc=aarch64-linux-android24-clang ;;
  x86_64) cc=x86_64-linux-android24-clang ;;
  *) echo "abi: arm64-v8a | x86_64" >&2; exit 2 ;;
esac
cc=$(echo "$ndk"/toolchains/llvm/prebuilt/*/bin)/$cc
sdk=${ANDROID_HOME:-$HOME/Library/Android/sdk}
out=$here/out/$abi
rm -rf "$out" && mkdir -p "$out/classes"
"$cc" -shared -fPIC -O1 -Wall -I"$bs/deps/mpv/include" -o "$out/libsurfprobe.so" \
  "$here/surfprobe.c" -L"$bs/prefix/$abi/lib" -lmpv
javac -source 8 -target 8 -nowarn -cp "$sdk/platforms/android-34/android.jar" \
  -d "$out/classes" "$here/SurfaceProbe.java" 2>&1 | grep -v -e warning -e '^Note' || true
"$sdk/build-tools/35.0.0/d8" --min-api 24 --lib "$sdk/platforms/android-34/android.jar" \
  --output "$out" "$out"/classes/*.class
rm -rf "$out/classes"
ls -la "$out"
