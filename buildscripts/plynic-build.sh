#!/bin/bash
# plynic-build.sh — build libmpv.so for one or more Android ABIs from this tree.
#
#   ./plynic-build.sh [--flavor full|plynic] [--mpv-only | --only t1,t2] [--clean] <arch>...
#     arch: arm64 | armv7l | x86_64 | x86  (default: arm64)
#
# Runs on the macOS host, no Docker: the NDK's macOS toolchain is a universal
# binary, while the Linux one is x86_64-only and would run emulated on Apple
# Silicon. Expects the NDK at sdk/android-sdk-linux/ndk/$v_ndk (a symlink is
# fine). A full build first runs include/download-deps.sh, which fetches any
# dependency that is missing or was fetched for another version than
# include/depinfo.sh pins (deps/<dep>/.plynic-pin); deps/mpv is never touched.
#
# deps/mpv is a symlink to the plynic-mpv fork, whose patches are commits.
# That is why patches/mpv no longer exists here: patch.sh does `git reset
# --hard` in every dep it patches, which would wipe uncommitted work in a fork.
#
# --mpv-only rebuilds just mpv against the already-built prefix — the inner
# loop while working on a VO (about 8s instead of 80s).
# --only t1,t2,... fetches (if needed) and rebuilds just those targets, in
# build order, against the prefix, e.g. after a version bump of one
# dependency: --only dav1d,ffmpeg,mpv.
# Static libraries are linked into libmpv.so, so mpv has to be in the list for
# a rebuilt dependency to reach it; ffmpeg has to follow mbedtls, dav1d or
# zlib, and freetype zlib.
set -u
cd "$(dirname "$0")"
export TRAVIS=1

flavor=full
mpv_only=0
only=""
clean=""
archs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --flavor) shift; flavor=$1 ;;
    --mpv-only) mpv_only=1 ;;
    --only) shift; only=$1 ;;
    --clean) clean="--clean" ;;
    arm64|armv7l|x86_64|x86) archs+=("$1") ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
[ ${#archs[@]} -eq 0 ] && archs=(arm64)
[ -f "flavors/$flavor.sh" ] || { echo "no such flavor: $flavor" >&2; exit 2; }

all_targets=(mbedtls dav1d libxml2 zlib ffmpeg freetype fribidi harfbuzz libass libiconv uchardet libplacebo mpv)
targets=("${all_targets[@]}")
[ $mpv_only -eq 1 ] && only=mpv
if [ -n "$only" ]; then
  for t in ${only//,/ }; do
    [[ " ${all_targets[*]} " == *" $t "* ]] || { echo "unknown target: $t" >&2; exit 2; }
  done
  targets=()
  for t in "${all_targets[@]}"; do
    [[ ",$only," == *",$t,"* ]] && targets+=("$t")
  done
  [ ${#targets[@]} -gt 0 ] || { echo "--only: no targets" >&2; exit 2; }
fi

mkdir -p logs
# Fetch what is missing or pinned differently: everything for a full build,
# just the listed targets for --only, nothing for --mpv-only.
fetch=()
[ -n "$only" ] && for t in "${targets[@]}"; do [ "$t" != mpv ] && fetch+=("$t"); done
if [ -z "$only" ] || [ ${#fetch[@]} -gt 0 ]; then
  ./include/download-deps.sh ${fetch[@]+"${fetch[@]}"} > logs/download.log 2>&1 \
    || { echo "DOWNLOAD FAILED"; tail -20 logs/download.log; exit 1; }
  grep '^fetching' logs/download.log || true
fi
# patch.sh resets and re-patches every dep under patches/ (today: ffmpeg).
for t in "${targets[@]}"; do
  if [ -d "patches/$t" ]; then
    ./patch.sh > logs/patch.log 2>&1 || { echo "PATCH FAILED"; tail -20 logs/patch.log; exit 1; }
    break
  fi
done
# The flavor IS the FFmpeg configure line; upstream CI copies it the same way.
cp "flavors/$flavor.sh" scripts/ffmpeg.sh
chmod +x scripts/*.sh

total_start=$(date +%s)
for arch in "${archs[@]}"; do
  for t in "${targets[@]}"; do
    s=$(date +%s)
    log="logs/build_${arch}_${t}.log"
    # mpv is always cleaned: meson bakes absolute paths into its build dir.
    c=$clean; [ "$t" = mpv ] && c="--clean"
    ./build.sh --arch "$arch" -n $c "$t" > "$log" 2>&1
    rc=$?
    printf '%-7s %-9s rc=%d %3ds\n' "$arch" "$t" "$rc" "$(( $(date +%s) - s ))"
    if [ $rc -ne 0 ]; then echo "FAILED — tail of $log:"; tail -30 "$log"; exit 1; fi
  done
done
echo "total $(( $(date +%s) - total_start ))s  flavor=$flavor"
for arch in "${archs[@]}"; do
  case "$arch" in arm64) p=arm64-v8a;; armv7l) p=armeabi-v7a;; *) p=$arch;; esac
  f="prefix/$p/lib/libmpv.so"
  [ -f "$f" ] && printf '%s  %s bytes  md5 %s\n' "$f" "$(stat -f %z "$f")" "$(md5 -q "$f")"
done
