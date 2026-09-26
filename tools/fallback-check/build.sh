#!/bin/bash
# build.sh [abi]: libfallprobe.so and the RotateProbe harness of
# tools/rotate-check (classes.dex) into out/<abi>/, against the mpv headers
# of buildscripts/deps/mpv and the libmpv.so of buildscripts/prefix/<abi>
# (link time only). Same requirements as tools/rotate-check/build.sh.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
bs=$here/../../buildscripts
abi=${1:-arm64-v8a}
"$here/../rotate-check/build.sh" "$abi" >/dev/null
. "$bs/include/depinfo.sh"
ndk=$bs/sdk/android-sdk-linux/ndk/$v_ndk
case $abi in
  arm64-v8a) cc=aarch64-linux-android29-clang ;;
  x86_64) cc=x86_64-linux-android29-clang ;;
  *) echo "abi: arm64-v8a | x86_64" >&2; exit 2 ;;
esac
cc=$(echo "$ndk"/toolchains/llvm/prebuilt/*/bin)/$cc
out=$here/out/$abi
rm -rf "$out" && mkdir -p "$out"
cp "$here/../rotate-check/out/$abi/classes.dex" "$out/"
"$cc" -shared -fPIC -O1 -Wall -I"$bs/deps/mpv/include" -o "$out/libfallprobe.so" \
  "$here/fallprobe.c" -L"$bs/prefix/$abi/lib" -lmpv
ls -la "$out"
