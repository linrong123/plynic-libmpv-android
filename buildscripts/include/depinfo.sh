#!/bin/bash -e

## Dependency versions

v_sdk=9123335_latest
v_ndk=25.2.9519653
v_sdk_build_tools=33.0.2
# mpv 0.41 needs meson >= 1.3.0; CI installs exactly this one (download-sdk.sh)
v_meson=1.10.0

# Sources fetched with git are pinned by tag AND commit: download-deps.sh
# refuses a checkout whose HEAD is not v_<dep>_commit (a tag can be moved).

v_libass=0.17.5
v_libass_commit=4a05d8127f525943ebf45fdc6497c9e665947f0d
v_harfbuzz=11.5.1
v_harfbuzz_commit=7497c4147469fd4102a7229222586ad5c743c5a1
v_fribidi=1.0.17
v_fribidi_commit=b93119f5fdc7ea47672cc304c1455ffa6dfe7536
v_freetype=2-13-3
v_freetype_commit=42608f77f20749dd6ddc9e0536788eaad70ea4b5
# mbedtls 3.6 LTS comes from the release tarball: a git checkout of the tag
# lacks the framework/ submodule the 3.6 Makefiles include.
v_mbedtls=3.6.7
v_mbedtls_sha256=a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6
v_dav1d=1.5.4
v_dav1d_commit=54706fc6bc0cdecab7e9593974a4039cc038fca7
v_libxml2=2.14.6
v_libxml2_commit=d23960a130c5bb82779c9405fbbf85e65fb3c57c
# Subtitle charset detection for mpv (-Diconv, -Duchardet): bionic only has
# iconv from API 28, the app's minSdk is 24.
v_libiconv=1.19
v_libiconv_sha256=88dd96a8c0464eca144fc791ae60cd31cd8ee78321e67397e25fc095c4a19aa6
v_uchardet=0.0.8
v_uchardet_sha256=e97a60cfc00a1c147a674b097bb1422abd9fa78a2d9ce3f3fdcc2e78a34ac5f0
v_ffmpeg=8.1.3
v_ffmpeg_commit=1041abdc962f4cc4f394aa8de9dc5236c0c3b9e7
# libplacebo: mpv 0.41 requires it (vo=gpu links its colour/shader helpers).
# Built with its git submodules (glad, jinja, markupsafe, fast_float,
# Vulkan-Headers), which the release tarballs lack; the tag commit pins them.
v_libplacebo=7.360.1
v_libplacebo_commit=cee9b076f2c63104ccfd497fa79c39a867293ec4
# plynic-mpv fork: upstream v0.41.0 + the plynic patch stack (branch
# plynic/v0.41.0 of the repo below; plynic/78d43740f5 is frozen and backs the
# v1.1.11-plynic.* releases). Pin the fork's commit, not the branch, so a
# rebuilt tag is bit-for-bit the same engine.
v_mpv=d75b92b584eacb8e3197ec03529f7de2693b9b00
v_mpv_repo=https://github.com/linrong123/plynic-mpv.git
# media-kit's Android helper: the jar's other .so files come from its APK
v_mkhelper_commit=42054e5d479f39ccbb0ae604862e2bcaf59b74c2
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
dep_libplacebo=()
dep_uchardet=()
dep_lua=()
dep_shaderc=()
if [ -n "${ENCODERS_GPL+x}" ]; then
	dep_mpv=(ffmpeg libass libplacebo libiconv uchardet fftools_ffi)
else
	dep_mpv=(ffmpeg libass libplacebo libiconv uchardet)
fi
