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
# libplacebo (mpv 0.41) is hidden the same way, and so is the C++ runtime it
# brings: its .pc adds -lc++, which --prefer-static resolves to the NDK's
# static libc++ (libc++_static.a + libc++abi.a, unwinder libunwind.a).
# Exported from libmpv.so, std::exception, operator new/delete and __cxa_*
# would be offered to every other library in the process. uchardet's
# operator new/delete (plynic.7: from the platform's libstdc++.so) now bind
# to that same static runtime, so libmpv.so has no DT_NEEDED on
# libstdc++.so any more, and must never get one on libc++_shared.so, which
# the app does not ship.
#
# compiler-rt's builtins archive (libclang_rt.builtins-<arch>-android.a,
# which the clang driver appends to every link) is hidden too: libc++abi's
# per-thread exception state (cxa_exception_storage.o) is thread_local, which
# goes through emulated TLS below API 29, and __emutls_get_address comes from
# that archive. rc1-rc3 exported it from libmpv.so on every ABI. The four
# names cover the four ABIs; lld ignores the ones not on the link line.
#
# zlib (scripts/zlib.sh, since rc5; the NDK sysroot's libz.a before) is
# hidden too: libmpv's own users (FFmpeg, FreeType, mpv) bind to it at link
# time, and nothing outside libmpv.so needs its API. rc1-rc4 and plynic.7
# exported the NDK copy's inflate/deflate/crc32/... from libmpv.so.
# -Dzlib=enabled: mpv's MKV header decompression (demux_mkv) needs it; a
# missing zlib fails the build.
#
# --print-archive-stats: how many members lld took from each static archive.
# include/static-system.py reads it after the build to record, in
# SOURCES.json, the libraries libmpv.so gets from the NDK itself (the LLVM
# runtimes), and refuses one it does not know.
#
# --no-undefined: mpv's meson.build sets b_lundef=false, so a symbol nothing
# on the link line defines used to become a silent dynamic import. On Android
# such a libmpv.so does not load at all ("cannot locate symbol"). The first
# uchardet link did exactly that (async_safe_fatal_no_abort, from the NDK's
# static libstdc++.a; see scripts/uchardet.sh). Every import now has to
# resolve against the API-level stubs of the NEEDED libraries at link time.
for f in lib/libiconv.a include/iconv.h lib/pkgconfig/uchardet.pc lib/pkgconfig/libplacebo.pc lib/pkgconfig/zlib.pc; do
	[ -e "$prefix_dir/$f" ] && continue
	echo "mpv: $prefix_dir/$f is missing; build zlib, libiconv, uchardet and libplacebo first" \
		"(plynic-build.sh without --mpv-only, or --only zlib,...,libiconv,uchardet,libplacebo,mpv)" >&2
	exit 1
done

# Version stamp (spec 0017 TD3): mpv-version reads
# "mpv v<MPV_VERSION>-plynic-g<first 9 hex digits of the commit>", e.g.
# "mpv v0.41.0-plynic-g1a2b3c4d5", whether the tree is a git checkout (here)
# or an exported source tree (the Darwin build, which stamps the same string
# into MPV_VERSION), so both platforms' engines say which fork commit they
# are. mpv's own common/meson.build would run `git describe` instead
# (v0.41.0-<n>-g<sha>, or v0.41.0-dev-g<sha> without the upstream tags). A
# second cross file points its find_program('git') at a stub that prints the
# stamp; the source tree is not touched. "-dirty" marks a local build of
# uncommitted work.
sha=$(git rev-parse HEAD)
dirty=
[ -n "$(git status --porcelain --untracked-files=no)" ] && dirty=-dirty
stamp="v$(cat MPV_VERSION)-plynic-g${sha:0:9}$dirty"
stub="$prefix_dir/plynic-mpv-version"
printf '#!/bin/sh\n# stands in for git describe, see scripts/mpv.sh\necho %s\n' "$stamp" > "$stub"
chmod +x "$stub"
printf "[binaries]\ngit = '%s'\n" "$stub" > "$prefix_dir/plynic-mpv-version.ini"
echo "mpv: version $stamp"

# The AOs are the ones plynic.7 had (audiotrack, opensles), and the Android
# features the app relies on are required, so a missing one fails the build
# instead of silently dropping out. aaudio (new since 0.38, dlopen()ed) stays
# off until the app wants it.
meson setup $build --cross-file "$prefix_dir"/crossfile.txt \
	--cross-file "$prefix_dir"/plynic-mpv-version.ini \
	--prefer-static \
	--default-library shared \
	-Dgpl=false \
	-Dlibmpv=true \
 	-Dlua=disabled \
 	-Dcplayer=false \
	-Diconv=enabled \
	-Duchardet=enabled \
	-Dzlib=enabled \
	-Dvulkan=disabled \
	-Daudiotrack=enabled \
	-Dopensles=enabled \
	-Daaudio=disabled \
	-Degl-android=enabled \
	-Dandroid-media-ndk=enabled \
 	-Dmanpage-build=disabled \
	-Dbuild-date=false \
	-Dc_args="-I$prefix_dir/include" \
	-Dc_link_args="$LDFLAGS -L$prefix_dir/lib -liconv -Wl,--exclude-libs,libz.a:libiconv.a:libuchardet.a:libplacebo.a:libc++_static.a:libc++abi.a:libunwind.a:libclang_rt.builtins-aarch64-android.a:libclang_rt.builtins-arm-android.a:libclang_rt.builtins-i686-android.a:libclang_rt.builtins-x86_64-android.a -Wl,--print-archive-stats=$prefix_dir/libmpv.archive-stats.tsv -Wl,--no-undefined -Wl,--build-id=sha1"

ninja -C $build -j$cores
DESTDIR="$prefix_dir" ninja -C $build install

ln -sf "$prefix_dir"/lib/libmpv.so "$native_dir"
