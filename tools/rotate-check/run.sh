#!/bin/bash
# run.sh <adb serial> <libmpv.so> <label>
#
# Rotation on Android, over adb (Android 10 or later: the harness's
# ImageReader takes usage flags; the plynic releases are checked on the
# Android 14 TV emulator, whose "hardware" VP9 the embed case needs).
#
# mpv rotates in the VO when the VO says it can (VO_CAP_ROTATE90: gpu, the
# render API), and otherwise inserts lavfi's `rotate` filter (the autorotate
# step of the video output chain). This build of FFmpeg has no `rotate`
# filter (--disable-filters, then overlay and equalizer only). The cases:
#
#   gpu         the texture path (vo=gpu into a Surface, software decoding):
#               video-rotate 0/90/180/270/0 on rot.mp4, each read back from
#               the Surface; no rotation filter is asked for
#   gpu-meta    the same with the rotation in the file (rot_meta90.mp4, a
#               display matrix of 90 degrees counter-clockwise, which FFmpeg
#               itself shows as GWRB), then video-rotate=90 on top of it
#   null        vo=null (media_kit's placeholder while there is no Surface)
#               on rot_meta90.mp4: the chain asks for the filter and logs
#               "filter 'rotate' not found or failed to allocate" (fatal)
#   legacy      the texture path with video-rotate=90, then a Surface change
#               in media_kit's order (vo=null, android-surface-size, wid,
#               vo=gpu): the fatal line while vo=null has the frames, and the
#               picture right afterwards
#   trackfirst  the same change in the order that parks the video track
#               first (vid=no ... vid=auto): no rotation filter asked for
#   embed       vo=mediacodec_embed, hwdec=mediacodec, rot_vp9.webm with
#               video-rotate=90: MediaCodec surface frames cannot be rotated
#               in software at all ("Video rotation with this format not
#               supported"), so a `rotate` filter would not change anything
#
# Output in out/<label>/, one RotateProbe log per case, judged by judge.py.
#
# The clips: four 160x90 quadrants, red green / blue white, 10 fps, 20 s:
#   q="color=0xff0000:s=160x90:r=10:d=20[a];color=0x00ff00:s=160x90:r=10:d=20[b];"
#   q="$q color=0x0000ff:s=160x90:r=10:d=20[c];color=0xffffff:s=160x90:r=10:d=20[d];"
#   q="$q [a][b][c][d]xstack=inputs=4:layout=0_0|w0_0|0_h0|w0_h0"
#   ffmpeg -f lavfi -i "$q" -c:v libx264 -preset veryslow -bf 0 -crf 30 -pix_fmt yuv420p \
#     -g 10 -an -map_metadata -1 -fflags +bitexact -flags +bitexact rot.mp4
#   ffmpeg -display_rotation 90 -i rot.mp4 -c copy -map_metadata -1 \
#     -fflags +bitexact rot_meta90.mp4
#   ffmpeg -f lavfi -i "$q" -c:v libvpx-vp9 -b:v 0 -crf 63 -g 10 -deadline good \
#     -cpu-used 8 -an -map_metadata -1 -fflags +bitexact -flags +bitexact rot_vp9.webm
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
serial=$1 lib=$2 label=$3
adb() { command adb -s "$serial" "$@"; }
abi=$(adb shell getprop ro.product.cpu.abi | tr -d '\r')
[ -f "$here/out/$abi/librotprobe.so" ] || { echo "run build.sh $abi first" >&2; exit 2; }
D=/data/local/tmp/rotate-check
adb shell "rm -rf $D && mkdir -p $D/lib" && \
adb push "$lib" $D/lib/libmpv.so >/dev/null && \
adb push "$here/out/$abi/librotprobe.so" "$here/out/$abi/classes.dex" \
  "$here/rot.mp4" "$here/rot_meta90.mp4" "$here/rot_vp9.webm" $D/ >/dev/null || exit 2
res=$here/out/$label
mkdir -p "$res"

probe() {  # probe <case> <expect> <WxH[:private]> <clip> <options and actions...>
  local name=$1 expect=$2 size=$3 clip=$4; shift 4
  adb shell "cd $D && LD_LIBRARY_PATH=$D/lib CLASSPATH=$D/classes.dex app_process /system/bin \
    RotateProbe $D/lib/libmpv.so $D/librotprobe.so $size $D/$clip ao=null loop-file=inf $*" \
    > "$res/$name.txt" 2>&1
  echo "== $name"
  "$here/judge.py" "$res/$name.txt" "$expect" || fail=1
}

gpu="vo=gpu gpu-context=android hwdec=no wid=@0 android-surface-size=640x640"
fail=0
probe gpu none 640x640 rot.mp4 $gpu +wait=1.5 +mark=RGBW \
  +set=video-rotate=90 +wait=1.2 +mark=BRWG +set=video-rotate=180 +wait=1.2 +mark=WBGR \
  +set=video-rotate=270 +wait=1.2 +mark=GWRB +set=video-rotate=0 +wait=1.2 +mark=RGBW \
  +get=current-vo +get=mpv-version
probe gpu-meta none 640x640 rot_meta90.mp4 $gpu +wait=1.5 +get=video-params/rotate +mark=GWRB \
  +set=video-rotate=90 +wait=1.2 +get=video-params/rotate +mark=RGBW
probe null fatal 640x640 rot_meta90.mp4 vo=null hwdec=no +wait=1.5 +get=video-params/rotate \
  +get=current-vo
probe legacy fatal 640x640 rot.mp4 $gpu video-rotate=90 +wait=1.5 +mark=BRWG \
  +set=vo=null +wait=0.3 +set=android-surface-size=640x640 +set=wid=@0 +set=vo=gpu \
  +wait=1.5 +mark=BRWG
probe trackfirst none 640x640 rot.mp4 $gpu video-rotate=90 +wait=1.5 +mark=BRWG \
  +set=vid=no +set=vo=null +wait=0.3 +set=android-surface-size=640x640 +set=wid=@0 \
  +set=vo=gpu +set=vid=auto +wait=1.5 +mark=BRWG
probe embed unsupported 640x640:private rot_vp9.webm vo=mediacodec_embed hwdec=mediacodec \
  wid=@0 video-rotate=90 +wait=2 +get=hwdec-current +get=video-params/rotate
exit $fail
