#!/bin/bash
# plynic-export.sh — stage built libmpv.so files for the app.
#
#   out/<abi>/libmpv.so             stripped; what PLYNIC_LIBMPV_PREFIX points at
#   out/<abi>/libmpv.unstripped.so  kept for symbolizing tombstones: the app's
#                                   crash records report `libmpv.so+0x<pc>` plus
#                                   a BuildId, and only this file turns that
#                                   into a function and a line
#   out/buildinfo.json              mpv commit, flavor, per-ABI md5 + BuildId
#
# Usage: ./plynic-export.sh           (every ABI present under prefix/)
set -eu
cd "$(dirname "$0")"
. include/depinfo.sh
ndk_bin=$(echo "$PWD/sdk/android-sdk-linux/ndk/$v_ndk/toolchains/llvm/prebuilt/"*)/bin
[ -x "$ndk_bin/llvm-strip" ] || { echo "llvm-strip not found under $ndk_bin" >&2; exit 1; }

mpv_commit=$(git -C deps/mpv rev-parse --short=10 HEAD)
mpv_dirty=$([ -n "$(git -C deps/mpv status --porcelain)" ] && echo true || echo false)
flavor=unknown
for f in flavors/*.sh; do cmp -s "$f" scripts/ffmpeg.sh && flavor=$(basename "$f" .sh); done

mkdir -p out
entries=""
for abi in arm64-v8a armeabi-v7a x86_64 x86; do
  src="prefix/$abi/lib/libmpv.so"
  [ -f "$src" ] || continue
  mkdir -p "out/$abi"
  cp "$src" "out/$abi/libmpv.unstripped.so"
  "$ndk_bin/llvm-strip" --strip-all -o "out/$abi/libmpv.so" "$src"
  md5=$(md5 -q "out/$abi/libmpv.so")
  size=$(stat -f %z "out/$abi/libmpv.so")
  bid=$("$ndk_bin/llvm-readelf" -n "$src" 2>/dev/null | awk '/Build ID/{print $3}')
  printf '%-12s %9s bytes  md5 %s  BuildId %s\n' "$abi" "$size" "$md5" "${bid:-none}"
  entries="$entries${entries:+,}\n    \"$abi\": {\"md5\": \"$md5\", \"size\": $size, \"build_id\": \"${bid:-}\"}"
done
printf '{\n  "mpv_commit": "%s",\n  "mpv_dirty": %s,\n  "flavor": "%s",\n  "ndk": "%s",\n  "abis": {%b\n  }\n}\n' \
  "$mpv_commit" "$mpv_dirty" "$flavor" "$v_ndk" "$entries" > out/buildinfo.json
echo "wrote out/buildinfo.json (mpv $mpv_commit dirty=$mpv_dirty flavor=$flavor)"
