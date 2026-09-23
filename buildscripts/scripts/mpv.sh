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

# $LDFLAGS is repeated on purpose: a c_link_args given on the command line
# REPLACES the one meson would have taken from the environment, and build.sh's
# LDFLAGS is where `-z max-page-size=16384` lives. Without it libmpv.so came
# out with 4 KiB PT_LOAD alignment — the app's verify_native_libs.sh --apk
# refused the first release for exactly that (16 KiB-page Android 15 devices
# would not load it).
#
# --build-id: the official libmpv.so carries no GNU build-id note, so a native
# crash inside the engine reports `libmpv.so+0x<pc>` with nothing to say WHICH
# libmpv.so that was. plynic's crash records and its `abnormal_exit` telemetry
# both key on the BuildId of the top frame; without the note every engine
# crash is unattributable to a build, and unsymbolizable once a second build
# exists. sha1 (not the default fast hash) so it is stable across linkers.
#
# iconv + uchardet: sub-codepage=auto (misc/charset_conv.c) guesses the
# charset of a non-UTF-8 external subtitle and converts it; without them a
# GBK/Big5/Shift_JIS .srt/.ass came out as Latin-1 mojibake. Both are static
# libraries in the prefix (scripts/libiconv.sh, scripts/uchardet.sh).
# meson's dependency('iconv') has no pkg-config method: it links a test
# calling iconv_open() with c_args/c_link_args ("builtin"), else looks for
# libiconv in the compiler's own search dirs, which never include the prefix.
# So the prefix's GNU iconv.h goes first on the include path (it maps
# iconv_open to libiconv_open; bionic's header only declares iconv for API
# 28+) and -liconv joins the link args, which puts it after mpv's objects on
# the final link. "enabled", not "auto": a missing library fails the build
# instead of silently shipping the mojibake again.
# --exclude-libs keeps the two archives' symbols out of libmpv.so's dynamic
# symbol table; nothing outside libmpv calls them.
#
# --no-undefined: mpv's meson.build sets b_lundef=false, so a symbol nothing
# on the link line defines used to become a silent dynamic import. On Android
# such a libmpv.so does not load at all ("cannot locate symbol"). The first
# uchardet link did exactly that (async_safe_fatal_no_abort, from the NDK's
# static libstdc++.a; see scripts/uchardet.sh). Every import now has to
# resolve against the API-level stubs of the NEEDED libraries at link time.
for f in lib/libiconv.a include/iconv.h lib/pkgconfig/uchardet.pc; do
	[ -e "$prefix_dir/$f" ] && continue
	echo "mpv: $prefix_dir/$f is missing; build libiconv and uchardet first" \
		"(plynic-build.sh without --mpv-only, or --only libiconv,uchardet)" >&2
	exit 1
done

meson setup $build --cross-file "$prefix_dir"/crossfile.txt \
	--prefer-static \
	--default-library shared \
	-Dgpl=false \
	-Dlibmpv=true \
 	-Dlua=disabled \
 	-Dcplayer=false \
	-Diconv=enabled \
	-Duchardet=enabled \
	-Dvulkan=disabled \
   	-Dlibplacebo=disabled \
 	-Dmanpage-build=disabled \
	-Dbuild-date=false \
	-Dc_args="-I$prefix_dir/include" \
	-Dc_link_args="$LDFLAGS -L$prefix_dir/lib -liconv -Wl,--exclude-libs,libiconv.a:libuchardet.a -Wl,--no-undefined -Wl,--build-id=sha1"

ninja -C $build -j$cores
DESTDIR="$prefix_dir" ninja -C $build install

ln -sf "$prefix_dir"/lib/libmpv.so "$native_dir"
