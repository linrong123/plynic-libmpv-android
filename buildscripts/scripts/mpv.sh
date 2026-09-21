#!/bin/bash -e

# $BUILD_ROOT, not ../../: this script runs with deps/mpv as cwd, which is a
# symlink into the plynic-mpv fork (see build.sh).
. "$BUILD_ROOT/include/depinfo.sh"
. "$BUILD_ROOT/include/path.sh"

build=_build$ndk_suffix

if [ "$1" == "build" ]; then
	true
elif [ "$1" == "clean" ]; then
	rm -rf _build$ndk_suffix
	exit 0
else
	exit 255
fi

unset CC CXX # meson wants these unset

meson setup $build --cross-file "$prefix_dir"/crossfile.txt \
	--prefer-static \
	--default-library shared \
	-Dgpl=false \
	-Dlibmpv=true \
 	-Dlua=disabled \
 	-Dcplayer=false \
	-Diconv=disabled \
	-Dvulkan=disabled \
   	-Dlibplacebo=disabled \
 	-Dmanpage-build=disabled \
	-Dbuild-date=false

ninja -C $build -j$cores
DESTDIR="$prefix_dir" ninja -C $build install

ln -sf "$prefix_dir"/lib/libmpv.so "$native_dir"
