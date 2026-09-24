#!/bin/bash -e

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

unset CC CXX # meson wants these unset

# -Dharfbuzz=disabled pins what a clean build (CI) gets anyway: freetype is
# built before harfbuzz, so meson's "auto" finds nothing there — but on any
# rebuild of freetype harfbuzz is already in the prefix and the autofitter's
# HarfBuzz support (af_shaper.c) got compiled in, a different libmpv.so from
# the same pins. libass renders with hinting off by default, so the
# autofitter is not what draws subtitles anyway.
#
# -Dzlib=system: the prefix's zlib (scripts/zlib.sh, found through its
# zlib.pc), or fail. "auto" would quietly fall back to a meson subproject,
# "internal" is the zlib copy in FreeType's own tree (src/gzip); either is a
# second zlib in libmpv.so.
meson setup $build --cross-file "$prefix_dir"/crossfile.txt \
	-Dharfbuzz=disabled \
	-Dzlib=system

ninja -C $build -j$cores
DESTDIR="$prefix_dir" ninja -C $build install
