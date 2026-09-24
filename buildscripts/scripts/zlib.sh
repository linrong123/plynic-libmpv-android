#!/bin/bash -e

# zlib, from the pinned release tarball (include/depinfo.sh: v_zlib,
# v_zlib_sha256), for FFmpeg (PNG, MKV/FLV/SWF content decompression, HTTP
# gzip ...), FreeType (gzip-compressed fonts) and mpv (MKV header
# compression).
#
# Up to rc4 libmpv.so linked the NDK sysroot's libz.a: zlib 1.2.12 (2022)
# plus AOSP's changes, with nothing in the NDK that says which AOSP revision
# it was built from, so a release could name its version but not its source.
# Building it here pins the source like every other dependency, publishes it
# with the release (collect-sources.sh), and keeps it current on devices
# whose system zlib never gets updated (why not the platform's libz.so).
#
# zlib's own configure script, not autoconf: CHOST makes it take the Linux
# branch whatever the host is (on macOS it would otherwise build the archive
# with Apple's libtool); CC, AR and RANLIB come from build.sh. --static
# builds libz.a only. It installs zlib.pc, through which FreeType (meson) and
# mpv (meson) find it; FFmpeg's configure finds zlib.h and -lz in the prefix
# before the sysroot's. scripts/mpv.sh hides it in libmpv.so like the other
# libraries nothing outside libmpv calls, and include/static-system.py fails
# the build if the sysroot's libz.a is linked instead.

. ../../include/depinfo.sh
. ../../include/path.sh

build=_build$ndk_suffix

if [ "$1" == "build" ]; then
	true
elif [ "$1" == "clean" ]; then
	rm -rf $build
	exit 0
else
	exit 255
fi

mkdir -p $build
cd $build

CHOST=$ndk_triple CFLAGS="-O2 -fPIC" ../configure --static --prefix=/usr/local
make -j$cores libz.a
make DESTDIR="$prefix_dir" install
grep -q "^Version: $v_zlib\$" "$prefix_dir/lib/pkgconfig/zlib.pc"
