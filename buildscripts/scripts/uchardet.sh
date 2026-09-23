#!/bin/bash -e
#
# uchardet, static, for mpv's sub-codepage=auto (misc/charset_conv.c): guesses
# the charset of a non-UTF-8 external subtitle (GBK, Big5, Shift_JIS,
# CP1251, ...) before libiconv converts it.
#
# Licence: uchardet is tri-licensed MPL-1.1 / GPL-2.0-or-later /
# LGPL-2.1-or-later; this build uses it under the LGPL-2.1-or-later, like the
# rest of libmpv.so.
#
# uchardet is C++, but it needs nothing from a C++ library beyond operator
# new/delete and __cxa_pure_virtual. It is compiled against the NDK's
# "system" runtime headers without exceptions or RTTI, so linking it only adds
# a DT_NEEDED on the platform's libstdc++.so (bionic's new/delete, present on
# every Android release and on the NDK's list of stable public libraries)
# instead of a static libc++ and its unwinder.
#
# The installed uchardet.pc says "Libs.private: -lstdc++", and mpv links with
# --prefer-static, so meson resolved that to the NDK's static libstdc++.a —
# which calls async_safe_fatal_no_abort, a bionic-internal symbol libc.so does
# not export. libmpv.so still linked (mpv builds with b_lundef=false) and
# would then have failed to dlopen on every device. The .pc is rewritten to
# name the shared library explicitly; meson warns that it cannot find
# "libstdc++.so" in the prefix and hands it to the linker, which takes it
# from the sysroot's API-level directory.

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

ndk="$DIR/sdk/android-sdk-linux/ndk/$v_ndk"
abi=$(basename "$prefix_dir")                       # arm64-v8a, armeabi-v7a, ...
api=$(echo "$CC" | sed -E 's/.*[^0-9]([0-9]+)-clang$/\1/')  # build.sh's apilvl

# CMAKE_POLICY_VERSION_MINIMUM: uchardet asks for cmake_minimum_required(3.1),
# which CMake 4 refuses without it; older CMake ignores the variable.
cmake -S . -B $build -G Ninja \
	-DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" \
	-DANDROID_ABI=$abi \
	-DANDROID_PLATFORM=android-$api \
	-DANDROID_STL=system \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_CXX_FLAGS="-fno-exceptions -fno-rtti" \
	-DCMAKE_INSTALL_PREFIX=/usr/local \
	-DCMAKE_INSTALL_LIBDIR=lib \
	-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
	-DBUILD_SHARED_LIBS=OFF \
	-DBUILD_BINARY=OFF

# Only the library: the default target also links test/uchardet-tests, a C
# program that CMake links without any C++ runtime.
ninja -C $build -j$cores libuchardet
DESTDIR="$prefix_dir" cmake --install $build

pc="$prefix_dir/lib/pkgconfig/uchardet.pc"
sed -e 's/^Libs.private: -lstdc++$/Libs.private: -l:libstdc++.so/' "$pc" > "$pc.tmp"
mv "$pc.tmp" "$pc"
grep -q '^Libs.private: -l:libstdc++.so$' "$pc" # fails loudly if upstream's .pc changes
