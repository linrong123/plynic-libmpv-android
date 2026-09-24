#!/bin/bash -e
#
# libplacebo, static, for mpv 0.41, which requires it: vo=gpu (the renderer
# the app uses) links its colour-space and shader helpers, and vo=gpu-next is
# built on it. LGPL-2.1-or-later.
#
# Only the OpenGL (ES) backend: no Vulkan (the app never asks mpv for it, and
# it would need the Vulkan loader and a SPIR-V compiler), no LittleCMS, no
# Dolby Vision reshaping, no demos/tests. Every optional dependency is named
# explicitly, so a library that happens to be in the prefix (or on the build
# host) cannot change what gets built.
#
# The OpenGL loader is generated at build time from the glad submodule by
# python3 (with the jinja/markupsafe submodules); Vulkan-Headers and
# fast_float are header-only. download-deps.sh clones them all at the commits
# libplacebo's tag pins.

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

meson setup $build --cross-file "$prefix_dir"/crossfile.txt \
	-Dvulkan=disabled -Dvk-proc-addr=disabled \
	-Dopengl=enabled -Dgl-proc-addr=enabled \
	-Dd3d11=disabled -Dglslang=disabled -Dshaderc=disabled \
	-Dlcms=disabled -Ddovi=disabled -Dlibdovi=disabled \
	-Dunwind=disabled -Dxxhash=disabled \
	-Ddemos=false -Dtests=false -Dbench=false -Dfuzz=false

ninja -C $build -j$cores
DESTDIR="$prefix_dir" ninja -C $build install

# libplacebo has C++ parts (fast_float number parsing), and its .pc does not
# say so, so a static link of libmpv.so would miss the C++ runtime. -lc++,
# not -lstdc++ (meson bug #11300). mpv links with --prefer-static, which
# resolves it to the NDK's static libc++ (libc++.a = libc++_static +
# libc++abi): libmpv.so must never get a DT_NEEDED on libc++_shared.so, which
# the app does not ship (the app's verify_native_libs.sh checks NEEDED).
pc="$prefix_dir/lib/pkgconfig/libplacebo.pc"
${SED:-sed} -e '/^Libs:/ s|$| -lc++|' "$pc" > "$pc.tmp"
mv "$pc.tmp" "$pc"
grep -q '^Libs:.* -lc++$' "$pc"
