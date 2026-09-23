#!/bin/bash -e
#
# ./include/download-deps.sh [dep...]
#   Without arguments: every dependency. With arguments: only the named pinned
#   dependencies (plynic-build.sh --only passes its targets).

. ./include/depinfo.sh

[ -z "$WGET" ] && WGET=wget

only=" $* "

mkdir -p deps && cd deps

# fetch <dir> <pin> <command...>
#   Runs <command> to populate <dir> unless <dir> already holds <pin>, the
#   source identity recorded in <dir>/.plynic-pin when it was fetched. A plain
#   "[ ! -d dir ]" kept an old checkout across a version bump in depinfo.sh,
#   so a local build went on compiling the previous release. A directory
#   without a pin file predates this check and is fetched again once.
fetch () {
	local dir=$1 pin=$2
	shift 2
	[ "$only" == "  " ] || [[ "$only" == *" $dir "* ]] || return 0
	if [ -d "$dir" ] && [ "$(cat "$dir/.plynic-pin" 2>/dev/null)" == "$pin" ]; then
		return 0
	fi
	echo "fetching $dir ($pin)"
	rm -rf "$dir"
	"$@"
	echo "$pin" > "$dir/.plynic-pin"
}

# tarball <dir> <url> <sha256>: download, check the digest, unpack into <dir>.
tarball () {
	local dir=$1 url=$2 want=$3 file=${2##*/} got
	rm -f "$file"
	$WGET "$url"
	got=$( (sha256sum "$file" 2>/dev/null || shasum -a 256 "$file") | cut -d' ' -f1)
	if [ "$got" != "$want" ]; then
		echo "$file: sha256 $got, expected $want" >&2
		rm -f "$file"
		return 1
	fi
	mkdir "$dir"
	tar -xf "$file" -C "$dir" --strip-components=1
	rm "$file"
}

# mbedtls
fetch mbedtls "mbedtls-$v_mbedtls.tar.bz2 $v_mbedtls_sha256" \
	tarball mbedtls https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-$v_mbedtls/mbedtls-$v_mbedtls.tar.bz2 $v_mbedtls_sha256

# dav1d
fetch dav1d "dav1d $v_dav1d" \
	git clone --depth 1 --branch $v_dav1d https://code.videolan.org/videolan/dav1d.git dav1d

# libxml2
fetch libxml2 "libxml2 v$v_libxml2" \
	git clone --depth 1 --branch v$v_libxml2 --recursive https://gitlab.gnome.org/GNOME/libxml2.git libxml2

# libiconv (GNU, LGPL-2.1+ library; only lib/ is built, see scripts/libiconv.sh)
fetch libiconv "libiconv-$v_libiconv.tar.gz $v_libiconv_sha256" \
	tarball libiconv https://ftp.gnu.org/pub/gnu/libiconv/libiconv-$v_libiconv.tar.gz $v_libiconv_sha256

# uchardet (MPL-1.1 / GPL-2.0+ / LGPL-2.1+, used under the LGPL)
fetch uchardet "uchardet-$v_uchardet.tar.xz $v_uchardet_sha256" \
	tarball uchardet https://www.freedesktop.org/software/uchardet/releases/uchardet-$v_uchardet.tar.xz $v_uchardet_sha256

# ffmpeg
fetch ffmpeg "ffmpeg n$v_ffmpeg" \
	git clone --depth 1 --branch n$v_ffmpeg https://github.com/FFmpeg/FFmpeg.git ffmpeg

# freetype2
fetch freetype "freetype VER-$v_freetype" \
	git clone --depth 1 --branch VER-$v_freetype https://gitlab.freedesktop.org/freetype/freetype.git freetype

# fribidi
fetch fribidi "fribidi v$v_fribidi" \
	git clone --depth 1 --branch v$v_fribidi https://github.com/fribidi/fribidi.git fribidi

# harfbuzz
fetch harfbuzz "harfbuzz $v_harfbuzz" \
	git clone --depth 1 --branch $v_harfbuzz https://github.com/harfbuzz/harfbuzz.git harfbuzz

# libass
fetch libass "libass $v_libass" \
	git clone --depth 1 --branch $v_libass https://github.com/libass/libass.git libass

[ "$only" == "  " ] || exit 0

# Everything below is fetched only when missing, and only by a full download.

# libogg
[ ! -d libogg ] && $WGET https://github.com/xiph/ogg/releases/download/v${v_libogg}/libogg-${v_libogg}.tar.gz && tar -xf libogg-${v_libogg}.tar.gz && mv libogg-${v_libogg} libogg && rm libogg-${v_libogg}.tar.gz

# libvorbis
[ ! -d libvorbis ] && $WGET https://github.com/xiph/vorbis/releases/download/v${v_libvorbis}/libvorbis-${v_libvorbis}.tar.gz && tar -xf libvorbis-${v_libvorbis}.tar.gz && mv libvorbis-${v_libvorbis} libvorbis && rm libvorbis-${v_libvorbis}.tar.gz

# libvpx
[ ! -d libvpx ] && git clone --depth 1 --branch meson-$v_libvpx https://gitlab.freedesktop.org/gstreamer/meson-ports/libvpx.git

# libx264
[ ! -d libx264 ] && git clone --depth 1 https://code.videolan.org/videolan/x264.git --branch master libx264

# shaderc
mkdir -p shaderc
cat >shaderc/README <<'HEREDOC'
Shaderc sources are provided by the NDK.
see <ndk>/sources/third_party/shaderc
HEREDOC

# mpv (never re-fetched: locally deps/mpv is a symlink to the plynic-mpv fork's
# working tree, see plynic-build.sh)
[ ! -d mpv ] && git clone $v_mpv_repo mpv && cd mpv && git reset --hard $v_mpv && cd ..

# fftools_ffi
[ ! -d fftools_ffi ] && git clone https://github.com/moffatman/fftools-ffi.git fftools_ffi && cd fftools_ffi && git reset --hard 9b0d4da026d9c830702ec043c1f1f98d407025af && cd ..

# media-kit-android-helper
[ ! -d media-kit-android-helper ] && git clone --branch main https://github.com/media-kit/media-kit-android-helper.git && cd media-kit-android-helper && git reset --hard 42054e5d479f39ccbb0ae604862e2bcaf59b74c2 && cd ..

# media_kit
[ ! -d media_kit ] && git clone --depth 1 --single-branch --branch main https://github.com/alexmercerind/media_kit.git

cd ..
