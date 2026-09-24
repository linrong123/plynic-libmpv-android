#!/bin/bash
# run.sh <adb serial> <libmpv.so> <label> [switch runs, default 20]
#
# Subtitles on vo_mediacodec_osd, on a device or emulator over adb (the
# Android 14 TV emulator is what the plynic releases were checked on; it
# decodes VP9 in "hardware", which the OSD VO needs):
#   1. keepout: paused on keepout.mkv, sid 2 (PGS) then 1 (ASS) then 2,
#      --sub-keepout 30/45/10/0 and back, playing with the band up, 20 -
#      once under the new name, once under vo-mediacodec-osd-sub-keepout.
#      judge.py keepout: each lift clears the band, moves and does not change
#      the subtitle, 0 restores it, each switch shows a subtitle; judge.py
#      compare: both names give the same OSD at every step.
#   2. switch: <n> fresh runs selecting the PGS track once while paused;
#      judge.py switch: every run ends on the same subtitle.
# Output in out/<label>/, one SurfaceProbe log per run. Needs build.sh first
# (the harness for the device's ABI) and Android 10 or later (the harness's
# video ImageReader takes usage flags). Fonts: the device's /system/fonts.
#
# keepout.mkv: 40 s of black VP9 (1280x720, 12 fps, libvpx), sid 1
# keepout.ass, sid 2 the PGS stream mksup.py writes (both shared with
# plynic-libmpv-darwin's tools/keepout; FFmpeg starts each input at 0, so the
# PGS runs 0-49 s in the MKV):
#   ffmpeg -f lavfi -i color=black:s=1280x720:r=12:d=40 -c:v libvpx-vp9 -b:v 0 \
#     -crf 63 -g 24 -deadline good -cpu-used 8 -bitexact -map_metadata -1 \
#     -fflags +bitexact black.webm
#   python3 mksup.py bottom.sup
#   ffmpeg -i black.webm -i keepout.ass -i bottom.sup -map 0:v -map 1:s -map 2:s \
#     -c copy -bitexact -fflags +bitexact -map_metadata -1 keepout.mkv
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
serial=$1 lib=$2 label=$3 n=${4:-20}
adb() { command adb -s "$serial" "$@"; }
abi=$(adb shell getprop ro.product.cpu.abi | tr -d '\r')
[ -f "$here/out/$abi/libsurfprobe.so" ] || { echo "run build.sh $abi first" >&2; exit 2; }
D=/data/local/tmp/osd-check
adb shell "rm -rf $D/lib $D/png && mkdir -p $D/lib $D/png" && \
adb push "$lib" $D/lib/libmpv.so >/dev/null && \
adb push "$here/out/$abi/libsurfprobe.so" "$here/out/$abi/classes.dex" "$here/keepout.mkv" $D/ >/dev/null || exit 2
res=$here/out/$label
mkdir -p "$res"

probe() {  # probe <out file> <options and actions...>
  local out=$1; shift
  adb shell "cd $D && LD_LIBRARY_PATH=$D/lib CLASSPATH=$D/classes.dex app_process /system/bin \
    SurfaceProbe $D/lib/libmpv.so $D/libsurfprobe.so osd 1280x720 $D/png $D/keepout.mkv \
    vo=mediacodec_osd hwdec=mediacodec wid=@0 vo-mediacodec-osd-surface=@1 ao=null \
    sub-fonts-dir=/system/fonts sub-font=Roboto $*; echo shell-rc=\$?" > "$out" 2>&1
}

fail=0
for name in sub-keepout vo-mediacodec-osd-sub-keepout; do
  s="+wait=1.5"
  for v in 30 45 10 0; do s="$s +set=$name=$v +wait=1"; done
  s="$s +set=sid=1 +wait=1.5"
  for v in 30 45 0; do s="$s +set=$name=$v +wait=1"; done
  s="$s +set=sid=2 +wait=1.5"
  for v in 30 0; do s="$s +set=$name=$v +wait=1"; done
  s="$s +set=sid=1 +wait=1 +set=$name=30 +wait=1 +set=pause=no +wait=4"
  s="$s +set=pause=yes +wait=0.8 +set=$name=0 +wait=1 +set=$name=20 +wait=1"
  s="$s +get=sub-keepout +get=vo-mediacodec-osd-sub-keepout +get=mpv-version"
  probe "$res/keepout-$name.txt" pause=yes start=10 sid=2 $s
  echo "== keepout ($name)"
  "$here/judge.py" keepout "$res/keepout-$name.txt" || fail=1
done
echo "== keepout: both names, same OSD"
"$here/judge.py" compare "$res/keepout-sub-keepout.txt" "$res/keepout-vo-mediacodec-osd-sub-keepout.txt" || fail=1

for i in $(seq "$n"); do
  probe "$res/switch-$i.txt" pause=yes start=10 sid=1 +wait=1.5 +set=sid=2 +wait=1.5
done
echo "== switch, $n runs"
"$here/judge.py" switch "$res"/switch-*.txt || fail=1
exit $fail
