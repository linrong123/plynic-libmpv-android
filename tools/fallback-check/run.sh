#!/bin/bash
# run.sh <adb serial> <libmpv.so> <label>
#
# What mpv does with a video stream no decoder can open, over adb (Android
# 10 or later, the RotateProbe harness of tools/rotate-check; the plynic
# releases are checked on the Android 14 TV emulator).
#
# hevc_bad_hvcc.mkv is hevc_good.mkv with its hvcC broken (mkbad.py): every
# libavcodec HEVC decoder, MediaCodec's wrapper included, refuses to open it
# ("Invalid NAL unit size in extradata."). Up to rc7, and in upstream mpv, a
# hardware decoder that failed to open made vd_lavc fall back until a
# decoder opened; when software decoding could not open either it tried
# software decoding again, forever, on the core thread under the core lock:
# every client call waited, and the decoder wrapper never logged "Failed to
# initialize a decoder for codec 'hevc'". rc8 tries software decoding once.
# Cases (fallprobe.c: ao=null, the core asked for time-pos once a second
# without blocking; a request unanswered for 3 s is "wedged"):
#   embed     vo=mediacodec_embed, hwdec=mediacodec (the app's TV path)
#   copy      vo=null, hwdec=mediacodec-copy
#   sw        vo=null, hwdec=no (never looped: no hardware attempt)
#   good      hevc_good.mkv, vo=null, hwdec=no: decodes, no failure
# Pass: the core answers throughout, the file (its audio) plays to the end,
# a handful of "Could not open codec." at most (8: one per decoding method
# for each decoder the wrapper tries; on rc7 it was 100 000 in 4 s), and the
# verdict line exactly once (never for good).
#
# The clips (4 s, 160x90 HEVC + AAC):
#   ffmpeg -f lavfi -i testsrc2=size=160x90:rate=10 -f lavfi -i sine=frequency=440:sample_rate=48000 \
#     -t 4 -c:v libx265 -x265-params log-level=error:info=0 -pix_fmt yuv420p -c:a aac -b:a 32k \
#     -map_metadata -1 -fflags +bitexact -flags +bitexact hevc_good.mkv
#   ./mkbad.py hevc_good.mkv hevc_bad_hvcc.mkv
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
serial=$1 lib=$2 label=$3
adb() { command adb -s "$serial" "$@"; }
abi=$(adb shell getprop ro.product.cpu.abi | tr -d '\r')
[ -f "$here/out/$abi/libfallprobe.so" ] || { echo "run build.sh $abi first" >&2; exit 2; }
D=/data/local/tmp/fallback-check
adb shell "rm -rf $D && mkdir -p $D/lib" && \
adb push "$lib" $D/lib/libmpv.so >/dev/null && \
adb push "$here/out/$abi/libfallprobe.so" "$here/out/$abi/classes.dex" \
  "$here/hevc_good.mkv" "$here/hevc_bad_hvcc.mkv" $D/ >/dev/null || exit 2
res=$here/out/$label
mkdir -p "$res"

pass=0 fail=0
check() {  # check <case> <max open failures> <verdicts> <WxH[:private]> <file> <options...>
  local name=$1 maxfail=$2 verdicts=$3 size=$4 clip=$5; shift 5
  adb shell "cd $D && LD_LIBRARY_PATH=$D/lib CLASSPATH=$D/classes.dex app_process /system/bin \
    RotateProbe $D/lib/libmpv.so $D/libfallprobe.so $size $D/$clip secs=8 $*" > "$res/$name.txt" 2>&1
  local opened verdict
  opened=$(sed -n 's/^COUNT *\([0-9]*\)  Could not open codec\..*/\1/p' "$res/$name.txt")
  verdict=$(sed -n 's/^COUNT *\([0-9]*\)  Failed to initialize a decoder.*/\1/p' "$res/$name.txt")
  echo "== $name"
  grep -E '^(RESULT|COUNT|  +[0-9.]+ END_FILE)' "$res/$name.txt" | sed 's/^/  /'
  if grep -q '^RESULT responsive' "$res/$name.txt" && grep -q 'END_FILE reason=0' "$res/$name.txt" \
     && [ "${opened:-x}" -le "$maxfail" ] 2>/dev/null && [ "${verdict:-x}" = "$verdicts" ]; then
    echo "  PASS"; pass=$((pass + 1))
  else
    echo "  FAIL"; fail=$((fail + 1))
  fi
}
check embed 8 1 640x640:private hevc_bad_hvcc.mkv vo=mediacodec_embed hwdec=mediacodec wid=@0
check copy 8 1 640x640 hevc_bad_hvcc.mkv vo=null hwdec=mediacodec-copy
check sw 8 1 640x640 hevc_bad_hvcc.mkv vo=null hwdec=no
check good 0 0 640x640 hevc_good.mkv vo=null hwdec=no
echo "SUMMARY fallback: $pass passed, $fail failed"
[ $fail -eq 0 ]
