#!/bin/bash -e

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

[ -f configure ] || NOCONFIGURE=1 ./autogen.sh

# Assembly is left to configure's own per-arch choice:
#   aarch64  libass/aarch64/*.S (NEON), assembled by the C compiler; no nasm.
#   x86_64   libass/x86/*.asm (SSE2/AVX2) through nasm, PIC via x86inc.
#   armv7    libass has no 32-bit ARM asm; configure turns it off by itself
#            (only an explicit --enable-asm would make that an error).
#   i686     nasm as well; x86inc's PIC mode also covers x86_32 (call/pop
#            LEA), and lld refuses text relocations unless given -z notext,
#            so a non-PIC object would fail the link instead of shipping
#            (FFmpeg's i686 --disable-asm in the flavor is a separate choice).
# --disable-asm used to be passed for every arch, leaving libass's blur,
# rasterizer and bitmap blending in plain C on the phones and TVs that render
# every ASS subtitle through them.
#
# -O2 is spelled out: a CFLAGS given to configure replaces autoconf's default
# "-g -O2", and with just -fPIC libass was compiled without optimisation.
mkdir -p _build$ndk_suffix
cd _build$ndk_suffix

../configure \
	CFLAGS="-O2 -fPIC" CXXFLAGS="-O2 -fPIC" \
	--host=$ndk_triple \
	--with-pic \
	--enable-static \
	--disable-shared \
	--disable-require-system-font-provider

make -j$cores
make DESTDIR="$prefix_dir" install
