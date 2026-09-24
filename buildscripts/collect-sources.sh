#!/bin/bash
# collect-sources.sh — the complete corresponding source of a plynic build.
#
#   ./collect-sources.sh [outdir]        (default: artifacts/plynic/sources)
#
# Run after include/download-deps.sh (every dependency fetched and pinned)
# and before or after patch.sh: nothing here reads a working tree. What
# libmpv.so is built from is published next to the jars, so that every
# LGPL/GPL-licensed library the app ships comes with its source from the
# same place (spec 0017 K-F):
#
#   src-<dep>-<version>.tar.xz   a dependency fetched with git: `git archive`
#                                of the pinned commit, plus its submodules
#                                (libplacebo) at the commits it pins; the
#                                files as git has them, no .git, no build dirs
#   <upstream tarball>           a dependency fetched as a release tarball
#                                (mbedtls, libiconv, uchardet, zlib): the very
#                                file upstream publishes, same sha256
#   src-mpv-<sha9>.tar.xz        the plynic-mpv fork at v_mpv (its patches are
#                                commits there)
#   patches-<tag>.tar.xz         buildscripts/patches: applied to the trees
#                                above by patch.sh, in file name order
#   plynic-libmpv-android-<tag>.tar.xz
#                                this repository at the commit being built
#                                (build scripts, flavors, patches)
#   src-media-kit-android-helper-<sha9>.tar.xz
#                                the jar's other .so file is built from it (as
#                                is: bundle_plynic.sh sets its NDK and link
#                                options from outside, include/helper.*)
#   SOURCES.json                 one entry per file: what it is, version,
#                                licence, upstream location and commit or
#                                digest, sha256, size, patches applied;
#                                after the build, include/static-system.py
#                                adds "static_system": what the jar's .so
#                                files link from the NDK as it is (the LLVM
#                                runtime), with no archive here, and
#                                "binaries"
#   SHA256SUMS                   sha256sum -c format
#
# Archives are deterministic for a given git and xz: git archive stamps
# every file with the commit time, the members are sorted, and xz runs
# single-threaded at its default preset.
set -euo pipefail
cd "$(dirname "$0")"
. include/depinfo.sh

out=${1:-artifacts/plynic/sources}
tag=${PLYNIC_TAG:-$(git describe --tags --always --dirty 2>/dev/null || echo local)}
rm -rf "$out"
mkdir -p "$out"
out=$(cd "$out" && pwd)

# gitsrc <name> <version> <dir>: $out/src-<name>-<version>.tar.xz from the
# commit checked out in <dir>, submodules included.
gitsrc () {
	local name=$1 ver=$2 dir=$3 f="src-$1-$2.tar.xz"
	python3 - "$dir" "$name-$ver" "$out/$f.tar" <<'PY'
import io, subprocess, sys, tarfile
top, prefix, dest = sys.argv[1:4]
def archive(repo, sub):
    data = subprocess.run(["git", "-C", repo, "archive", "--format=tar", "HEAD"],
                          check=True, capture_output=True).stdout
    with tarfile.open(fileobj=io.BytesIO(data)) as t:
        for m in t.getmembers():
            if m.type == tarfile.XGLTYPE:  # git's pax comment with the commit id
                continue
            yield (f"{prefix}/{sub}{m.name}".rstrip("/"), m,
                   t.extractfile(m).read() if m.isfile() else None)
subs = subprocess.run(["git", "-C", top, "submodule", "--quiet", "foreach", "--recursive",
                       "echo $displaypath"], check=True, capture_output=True, text=True).stdout.split()
members = list(archive(top, ""))
for s in subs:
    members += archive(f"{top}/{s}", f"{s}/")
seen = set()
with tarfile.open(dest, "w", format=tarfile.PAX_FORMAT) as t:
    for name, m, data in sorted(members, key=lambda x: x[0]):
        if name in seen:   # a submodule's own directory entry
            continue
        seen.add(name)
        m.name = name
        m.uid = m.gid = 0
        m.uname = m.gname = ""
        m.pax_headers = {}
        t.addfile(m, io.BytesIO(data) if data is not None else None)
PY
	xz -T1 -c "$out/$f.tar" > "$out/$f"
	rm "$out/$f.tar"
	echo "$f"
}

# copy <upstream tarball in deps/.tarballs>
copy () {
	cp -p "deps/.tarballs/$1" "$out/$1"
	echo "$1"
}

need () {
	[ -e "deps/$1" ] || { echo "deps/$1 is missing: run include/download-deps.sh first" >&2; exit 1; }
}
for d in mbedtls dav1d libxml2 libiconv uchardet zlib ffmpeg freetype fribidi harfbuzz libass libplacebo mpv media-kit-android-helper; do
	need "$d"
done
for t in "mbedtls-$v_mbedtls.tar.bz2" "libiconv-$v_libiconv.tar.gz" "uchardet-$v_uchardet.tar.xz" "zlib-$v_zlib.tar.xz"; do
	[ -f "deps/.tarballs/$t" ] || { echo "deps/.tarballs/$t is missing: fetch it again (rm -rf deps/${t%%-*})" >&2; exit 1; }
done

# The commit a git dependency is checked out at has to be the one depinfo.sh
# pins (download-deps.sh verifies this when it clones; a later checkout
# could have moved it).
pinned () {
	local got
	got=$(git -C "deps/$1" rev-parse HEAD)
	[ "$got" == "$2" ] || { echo "deps/$1 is at $got, depinfo.sh pins $2" >&2; exit 1; }
}
pinned ffmpeg "$v_ffmpeg_commit"
pinned libplacebo "$v_libplacebo_commit"
pinned dav1d "$v_dav1d_commit"
pinned libxml2 "$v_libxml2_commit"
pinned freetype "$v_freetype_commit"
pinned fribidi "$v_fribidi_commit"
pinned harfbuzz "$v_harfbuzz_commit"
pinned libass "$v_libass_commit"
pinned mpv "$v_mpv"
pinned media-kit-android-helper "$v_mkhelper_commit"

echo "collecting sources into $out"
gitsrc ffmpeg "$v_ffmpeg" deps/ffmpeg
gitsrc libplacebo "$v_libplacebo" deps/libplacebo
gitsrc dav1d "$v_dav1d" deps/dav1d
gitsrc libxml2 "$v_libxml2" deps/libxml2
gitsrc freetype "${v_freetype//-/.}" deps/freetype
gitsrc fribidi "$v_fribidi" deps/fribidi
gitsrc harfbuzz "$v_harfbuzz" deps/harfbuzz
gitsrc libass "$v_libass" deps/libass
gitsrc mpv "${v_mpv:0:9}" deps/mpv
gitsrc media-kit-android-helper "${v_mkhelper_commit:0:9}" deps/media-kit-android-helper
copy "mbedtls-$v_mbedtls.tar.bz2"
copy "libiconv-$v_libiconv.tar.gz"
copy "uchardet-$v_uchardet.tar.xz"
copy "zlib-$v_zlib.tar.xz"

# The patches, and this repository itself (git archive of HEAD: a local
# build with uncommitted changes says so in the file name).
# (python's tarfile rather than tar: GNU and BSD tar differ in how to make
# an archive deterministic.)
python3 - "$out/patches-$tag.tar" <<'PY'
import os, sys, tarfile
names = []
for root, dirs, files in os.walk("patches"):
    names += [root] + [os.path.join(root, f) for f in files]
with tarfile.open(sys.argv[1], "w", format=tarfile.PAX_FORMAT) as t:
    for n in sorted(names):
        ti = t.gettarinfo(n)
        ti.mtime = 0
        ti.mode = 0o755 if ti.isdir() else 0o644
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = ""
        if ti.isfile():
            with open(n, "rb") as data:
                t.addfile(ti, data)
        else:
            t.addfile(ti)
PY
xz -T1 -f "$out/patches-$tag.tar"
echo "patches-$tag.tar.xz"
git -C "$(git rev-parse --show-toplevel)" archive --format=tar --prefix="plynic-libmpv-android-$tag/" HEAD \
	| xz -T1 > "$out/plynic-libmpv-android-$tag.tar.xz"
echo "plynic-libmpv-android-$tag.tar.xz"

# SOURCES.json + SHA256SUMS
python3 - "$out" "$tag" <<PY
import hashlib, json, os, sys
out, tag = sys.argv[1:3]
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()
patches = []
for root, _, files in os.walk("patches"):
    for f in sorted(files):
        p = os.path.join(root, f)
        patches.append({"file": p, "applies_to": p.split(os.sep)[1], "sha256": sha(p)})
patches.sort(key=lambda p: p["file"])
def ffpatches(dep):
    return [p["file"] for p in patches if p["applies_to"] == dep]
E = []
def add(file, id, version, license, upstream, **kw):
    E.append(dict(file=file, id=id, version=version, license=license, upstream=upstream, **kw))
add("src-ffmpeg-$v_ffmpeg.tar.xz", "ffmpeg", "$v_ffmpeg", "LGPL-3.0-or-later",
    "https://github.com/FFmpeg/FFmpeg", tag="n$v_ffmpeg", commit="$v_ffmpeg_commit",
    patches=ffpatches("ffmpeg"), note="configured --disable-gpl --enable-version3, see flavors/plynic.sh")
add("src-libplacebo-$v_libplacebo.tar.xz", "libplacebo", "$v_libplacebo", "LGPL-2.1-or-later",
    "https://code.videolan.org/videolan/libplacebo", tag="v$v_libplacebo", commit="$v_libplacebo_commit",
    note="with its submodules at the commits the tag pins: glad (MIT; the OpenGL loader it generates: "
         "(WTFPL OR CC0-1.0) AND Apache-2.0), fast_float (Apache-2.0 OR MIT OR BSL-1.0), "
         "Vulkan-Headers (Apache-2.0 OR MIT; headers only, Vulkan is disabled), jinja and markupsafe "
         "(BSD-3-Clause; build-time code generation only)")
add("src-dav1d-$v_dav1d.tar.xz", "dav1d", "$v_dav1d", "BSD-2-Clause",
    "https://code.videolan.org/videolan/dav1d", tag="$v_dav1d", commit="$v_dav1d_commit")
add("src-libxml2-$v_libxml2.tar.xz", "libxml2", "$v_libxml2", "MIT",
    "https://gitlab.gnome.org/GNOME/libxml2", tag="v$v_libxml2", commit="$v_libxml2_commit")
add("src-freetype-${v_freetype//-/.}.tar.xz", "freetype", "${v_freetype//-/.}", "FTL OR GPL-2.0-or-later",
    "https://gitlab.freedesktop.org/freetype/freetype", tag="VER-$v_freetype", commit="$v_freetype_commit",
    note="used under the FreeType License")
add("src-fribidi-$v_fribidi.tar.xz", "fribidi", "$v_fribidi", "LGPL-2.1-or-later",
    "https://github.com/fribidi/fribidi", tag="v$v_fribidi", commit="$v_fribidi_commit")
add("src-harfbuzz-$v_harfbuzz.tar.xz", "harfbuzz", "$v_harfbuzz", "MIT-Modern-Variant",
    "https://github.com/harfbuzz/harfbuzz", tag="$v_harfbuzz", commit="$v_harfbuzz_commit")
add("src-libass-$v_libass.tar.xz", "libass", "$v_libass", "ISC",
    "https://github.com/libass/libass", tag="$v_libass", commit="$v_libass_commit")
add("src-mpv-${v_mpv:0:9}.tar.xz", "mpv", "${v_mpv:0:9}", "LGPL-2.1-or-later",
    "$v_mpv_repo".removesuffix(".git"), commit="$v_mpv",
    note="plynic-mpv: upstream mpv plus the plynic patches as commits; built with -Dgpl=false")
add("src-media-kit-android-helper-${v_mkhelper_commit:0:9}.tar.xz", "media-kit-android-helper",
    "${v_mkhelper_commit:0:9}", "MIT", "https://github.com/media-kit/media-kit-android-helper",
    commit="$v_mkhelper_commit",
    note="builds the jar's libmediakitandroidhelper.so, from this tree as it is: the NDK and the link "
         "options (hidden exports) come from include/helper.init.gradle and include/helper.cmake of "
         "plynic-libmpv-android")
add("mbedtls-$v_mbedtls.tar.bz2", "mbedtls", "$v_mbedtls", "Apache-2.0 OR GPL-2.0-or-later",
    "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-$v_mbedtls/mbedtls-$v_mbedtls.tar.bz2",
    upstream_sha256="$v_mbedtls_sha256", note="upstream release tarball as published; used under Apache-2.0")
add("libiconv-$v_libiconv.tar.gz", "libiconv", "$v_libiconv", "LGPL-2.1-or-later",
    "https://ftp.gnu.org/pub/gnu/libiconv/libiconv-$v_libiconv.tar.gz",
    upstream_sha256="$v_libiconv_sha256", note="upstream release tarball as published; only the library is built")
add("uchardet-$v_uchardet.tar.xz", "uchardet", "$v_uchardet", "MPL-1.1 OR GPL-2.0-or-later OR LGPL-2.1-or-later",
    "https://www.freedesktop.org/software/uchardet/releases/uchardet-$v_uchardet.tar.xz",
    upstream_sha256="$v_uchardet_sha256", note="upstream release tarball as published; used under LGPL-2.1-or-later")
add("zlib-$v_zlib.tar.xz", "zlib", "$v_zlib", "Zlib",
    "https://github.com/madler/zlib/releases/download/v$v_zlib/zlib-$v_zlib.tar.xz",
    upstream_sha256="$v_zlib_sha256",
    note="upstream release tarball as published (also on zlib.net, same sha256; signed by Mark Adler, "
         "OpenPGP key 5ED46A6721D365587791E2AA783FCD8E58BCAFBA); only libz.a is built (scripts/zlib.sh), "
         "hidden in libmpv.so")
add(f"patches-{tag}.tar.xz", "patches", tag, "LGPL-3.0-or-later", "",
    note="buildscripts/patches, applied by patch.sh in file name order; under the terms of the FFmpeg "
         "code they change. upstream_*.patch are FFmpeg's own commits (git format-patch), backported")
add(f"plynic-libmpv-android-{tag}.tar.xz", "plynic-libmpv-android", tag, "MIT",
    "https://github.com/linrong123/plynic-libmpv-android", note="the build scripts (git archive)")
for e in E:
    p = os.path.join(out, e["file"])
    e["sha256"] = sha(p)
    e["size"] = os.path.getsize(p)
    if e.get("upstream_sha256") and e["upstream_sha256"] != e["sha256"]:
        sys.exit(f"{e['file']}: sha256 differs from upstream's")
doc = {"tag": tag, "ndk": "$v_ndk", "patches": patches, "sources": E}
json.dump(doc, open(os.path.join(out, "SOURCES.json"), "w"), indent=2)
with open(os.path.join(out, "SHA256SUMS"), "w") as f:
    for e in E + [{"file": "SOURCES.json", "sha256": sha(os.path.join(out, "SOURCES.json"))}]:
        f.write(f"{e['sha256']}  {e['file']}\n")
print(f"SOURCES.json: {len(E)} files, {sum(e['size'] for e in E) / 1e6:.1f} MB")
PY
