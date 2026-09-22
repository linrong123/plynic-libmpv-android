#!/bin/bash -e

## Dependency versions

v_sdk=9123335_latest
v_ndk=25.2.9519653
v_sdk_build_tools=33.0.2

v_libass=0.17.5
v_harfbuzz=11.5.1
v_fribidi=1.0.17
v_freetype=2-13-3
v_mbedtls=3.4.0
v_dav1d=1.2.0
v_libxml2=2.14.6
v_ffmpeg=6.0
# plynic-mpv fork: upstream 78d43740f5 + the plynic patch stack (default
# branch plynic/78d43740f5 of the repo below). Pin the fork's commit, not the
# branch, so a rebuilt tag is bit-for-bit the same engine.
v_mpv=da0a1d8411aa3a5ecf9b7844a779371d8971229c
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
dep_lua=()
dep_shaderc=()
if [ -n "${ENCODERS_GPL+x}" ]; then
	dep_mpv=(ffmpeg libass fftools_ffi)
else
	dep_mpv=(ffmpeg libass)
fi
