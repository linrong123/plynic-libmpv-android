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

# --build-id: the official libmpv.so carries no GNU build-id note, so a native
# crash inside the engine reports `libmpv.so+0x<pc>` with nothing to say WHICH
# libmpv.so that was. plynic's crash records and its `abnormal_exit` telemetry
# both key on the BuildId of the top frame; without the note every engine
# crash is unattributable to a build, and unsymbolizable once a second build
# exists. sha1 (not the default fast hash) so it is stable across linkers.

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
	-Dbuild-date=false \
	-Dc_link_args='-Wl,--build-id=sha1'

ninja -C $build -j$cores
DESTDIR="$prefix_dir" ninja -C $build install

ln -sf "$prefix_dir"/lib/libmpv.so "$native_dir"
