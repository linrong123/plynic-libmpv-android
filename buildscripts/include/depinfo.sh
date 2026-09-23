#!/bin/bash -e

## Dependency versions

v_sdk=9123335_latest
v_ndk=25.2.9519653
v_sdk_build_tools=33.0.2

v_libass=0.17.5
v_harfbuzz=11.5.1
v_fribidi=1.0.17
v_freetype=2-13-3
# mbedtls 3.6 LTS comes from the release tarball: a git checkout of the tag
# lacks the framework/ submodule the 3.6 Makefiles include.
v_mbedtls=3.6.7
v_mbedtls_sha256=a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6
v_dav1d=1.5.4
v_libxml2=2.14.6
# Subtitle charset detection for mpv (-Diconv, -Duchardet): bionic only has
# iconv from API 28, the app's minSdk is 24.
v_libiconv=1.19
v_libiconv_sha256=88dd96a8c0464eca144fc791ae60cd31cd8ee78321e67397e25fc095c4a19aa6
v_uchardet=0.0.8
v_uchardet_sha256=e97a60cfc00a1c147a674b097bb1422abd9fa78a2d9ce3f3fdcc2e78a34ac5f0
v_ffmpeg=6.0
# plynic-mpv fork: upstream 78d43740f5 + the plynic patch stack (default
# branch plynic/78d43740f5 of the repo below). Pin the fork's commit, not the
# branch, so a rebuilt tag is bit-for-bit the same engine.
v_mpv=ed162a9101728581ccc374e5cec876ea74114903
v_mpv_repo=https://github.com/linrong123/plynic-mpv.git
v_libogg=1.3.5
v_libvorbis=1.3.7
v_libvpx=1.13


## Dependency tree
# I would've used a dict but putting arrays in a dict is not a thing

dep_mbedtls=()
dep_dav1d=()
dep_libvorbis=(libogg)
if [ -n "${ENCODERS_GPL+x}" ]; then
	dep_ffmpeg=(mbedtls dav1d libxml2 libvorbis libvpx libx264)
else
	dep_ffmpeg=(mbedtls dav1d libxml2)
fi
dep_freetype2=()
dep_fribidi=()
dep_harfbuzz=()
dep_libass=(freetype fribidi harfbuzz)
dep_libiconv=()
dep_uchardet=()
dep_lua=()
dep_shaderc=()
if [ -n "${ENCODERS_GPL+x}" ]; then
	dep_mpv=(ffmpeg libass libiconv uchardet fftools_ffi)
else
	dep_mpv=(ffmpeg libass libiconv uchardet)
fi
