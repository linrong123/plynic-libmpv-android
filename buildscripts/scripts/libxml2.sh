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

mkdir -p _build$ndk_suffix
cd _build$ndk_suffix

# -O2 is spelled out: a CFLAGS given to configure replaces autoconf's default
# "-g -O2", and with just -fPIC libxml2 was compiled without optimisation.
../configure \
    CFLAGS="-O2 -fPIC" CXXFLAGS="-O2 -fPIC" \
	--host=$ndk_triple \
    --disable-shared \
    --enable-static \
    --with-minimum \
    --with-threads \
    --with-tree \
    --without-lzma \

make -j$cores
make DESTDIR="$prefix_dir" install
