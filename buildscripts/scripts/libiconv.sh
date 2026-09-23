#!/bin/bash -e
#
# GNU libiconv, static, for mpv's subtitle charset conversion
# (misc/charset_conv.c: sub-codepage=auto -> uchardet guess -> iconv to UTF-8).
# bionic's own iconv only exists from API 28 (the app's minSdk is 24), and the
# header only declares it for __ANDROID_API__ >= 28, so it cannot be used.
#
# Licence: the library (lib/, libcharset/) is LGPL-2.1-or-later, the same as
# this libmpv build. The iconv(1) program and the gnulib it pulls in (src/,
# srclib/) are GPL-3.0 and are never built: only lib/localcharset.h (from
# libcharset/) and lib/ are made and installed.
#
# GNU iconv.h renames the API (iconv_open -> libiconv_open, ...), so nothing
# built against it can bind to bionic's iconv by accident on API 28+ devices.

. ../../include/depinfo.sh
. ../../include/path.sh

if [ "$1" == "build" ]; then
	true
elif [ "$1" == "clean" ]; then
	rm -rf _build$ndk_suffix
	exit 0
else
	exit 255
fi

mkdir -p _build$ndk_suffix
cd _build$ndk_suffix

# The default encoding set: every Windows codepage, ISO-8859-*, KOI8-*, and
# for CJK GBK/CP936/GB18030, Big5/CP950/Big5-HKSCS, EUC-TW, Shift_JIS/CP932,
# EUC-JP, ISO-2022-*, EUC-KR/CP949/JOHAB, plus TIS-620 and VISCII. It is
# most of the ~0.9 MB libiconv adds to libmpv.so (arm64, stripped).
# Not --enable-extra-encodings: another ~160 KB, and of what uchardet can
# answer it only adds the DOS codepages IBM852/IBM855/IBM865, which subtitle
# files practically never use (mpv falls back to Latin-1 for those).
../configure \
	CFLAGS="-O2" \
	--host=$ndk_triple \
	--with-pic \
	--enable-static \
	--disable-shared \
	--disable-nls

make -j$cores lib/localcharset.h
make -j$cores -C lib
make -C lib DESTDIR="$prefix_dir" install
mkdir -p "$prefix_dir/include"
cp include/iconv.h.inst "$prefix_dir/include/iconv.h"
