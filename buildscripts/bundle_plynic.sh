#!/bin/bash
# bundle_plynic.sh — CI entry point for the plynic flavor (Linux host).
#
# Same shape as bundle_full.sh, with three differences that matter to the app:
#   * flavor = plynic (see flavors/plynic.sh), mpv from the plynic-mpv fork
#     (include/depinfo.sh: v_mpv / v_mpv_repo);
#   * every artifact is named plynic-<abi>.jar, and next to the jars there is a
#     manifest.json with md5 / sha256 / size of each jar AND of the libmpv.so
#     inside it, plus the GNU build-id — tool/native_libs.lock.json in the
#     plynic app is filled from that file, nothing is typed by hand;
#   * the unstripped libmpv.so of every ABI is kept (debug-symbols-plynic.zip):
#     the app's crash records report `libmpv.so+0x<pc>` with the build-id, and
#     only the unstripped file turns that into a function and a line;
#   * the complete corresponding source goes next to them (sources/, see
#     collect-sources.sh), collected from the pinned trees before patch.sh
#     touches them, and listed in the manifest;
#   * what the jar's two .so files take from the NDK as it is (the LLVM
#     runtime) is added to SOURCES.json after the build, per binary and ABI,
#     from lld's archive stats and the binaries' dynamic symbol tables
#     (include/static-system.py), and copied into the manifest;
#   * media-kit-android-helper (the jar's libmediakitandroidhelper.so) is
#     built with the NDK libmpv.so is built with and exports only its own
#     API (include/helper.init.gradle, include/helper.cmake); its tree stays
#     the pinned commit.
set -euxo pipefail
cd "$(dirname "$0")"
root=$PWD

rm -rf deps prefix artifacts
./download.sh
./collect-sources.sh artifacts/plynic/sources
./patch.sh

cp flavors/plynic.sh scripts/ffmpeg.sh
chmod +x scripts/*.sh

./build.sh

. ./include/depinfo.sh
abis=(arm64-v8a armeabi-v7a x86 x86_64)
ndk_bin=$(echo "$PWD/sdk/android-sdk-linux/ndk/$v_ndk/toolchains/llvm/prebuilt/"*)/bin

# The helper APK provides the jar's other .so file (media-kit's android
# helper); libmpv.so is swapped in below, exactly as bundle_full.sh does.
# Built with this repository's NDK and settings from the outside
# (include/helper.init.gradle); its lld archive stats land next to
# libmpv.so's in prefix/<abi>/.
apk=deps/media-kit-android-helper/app/build/outputs/apk/release
pushd deps/media-kit-android-helper
chmod +x gradlew
./gradlew --init-script "$root/include/helper.init.gradle" \
  -Pplynic.ndkVersion="$v_ndk" \
  -Pplynic.cmakeInclude="$root/include/helper.cmake" \
  -Pplynic.archiveStatsDir="$root/prefix" \
  assembleRelease
popd
unzip -o "$apk/app-release.apk" 'lib/*' -d "$apk"

./include/static-system.py artifacts/plynic/sources "sdk/android-sdk-linux/ndk/$v_ndk" \
  $(for abi in "${abis[@]}"; do
      echo "prefix/$abi/libmpv.archive-stats.tsv=prefix/$abi/usr/local/lib/libmpv.so"
      echo "prefix/$abi/libmediakitandroidhelper.archive-stats.tsv=$apk/lib/$abi/libmediakitandroidhelper.so"
    done)

# Unstripped copies first; the jars get the stripped ones.
mkdir -p artifacts/plynic/symbols
for abi in "${abis[@]}"; do
  mkdir -p "artifacts/plynic/symbols/$abi"
  cp "prefix/$abi/usr/local/lib/libmpv.so" "artifacts/plynic/symbols/$abi/libmpv.so"
  "$ndk_bin/llvm-strip" --strip-all "prefix/$abi/usr/local/lib/libmpv.so"
done
(cd artifacts/plynic && zip -qr debug-symbols-plynic.zip symbols && rm -rf symbols)

for abi in "${abis[@]}"; do
  cp "prefix/$abi/usr/local/lib/libmpv.so" "$apk/lib/$abi/"
done
pushd "$apk"
for abi in "${abis[@]}"; do
  rm -f "plynic-$abi.jar"
  zip -r "plynic-$abi.jar" "lib/$abi/"*.so
done
popd
cp "$apk"/plynic-*.jar artifacts/plynic/

# manifest.json: the numbers the app's lock file pins.
# Every library linked into libmpv.so, with the version depinfo.sh pins; the
# app copies this "deps" object into tool/native_libs.lock.json verbatim.
python3 - "$ndk_bin" "${abis[@]}" <<PY
import hashlib, json, os, re, subprocess, sys, zipfile
ndk_bin = sys.argv[1]
abis = sys.argv[2:]
def digests(data):
    return {"md5": hashlib.md5(data).hexdigest(), "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
def readelf(*args):
    return subprocess.run([f"{ndk_bin}/llvm-readelf", *args], check=True, capture_output=True, text=True).stdout
sources = json.load(open("artifacts/plynic/sources/SOURCES.json"))
out = {"flavor": "plynic", "tag": os.environ.get("PLYNIC_TAG", ""),
       "mpv_commit": "$v_mpv", "mpv_repo": "$v_mpv_repo",
       # what the mpv-version property reports (scripts/mpv.sh stamps it)
       "mpv_version": "v" + open("deps/mpv/MPV_VERSION").read().strip() + "-plynic-g" + "$v_mpv"[:9],
       "ndk": "$v_ndk", "meson": "$v_meson",
       "deps": {"ffmpeg": "$v_ffmpeg", "libplacebo": "$v_libplacebo", "libass": "$v_libass",
                "harfbuzz": "$v_harfbuzz", "freetype": "${v_freetype//-/.}", "fribidi": "$v_fribidi",
                "libxml2": "$v_libxml2", "mbedtls": "$v_mbedtls", "dav1d": "$v_dav1d",
                "libiconv": "$v_libiconv", "uchardet": "$v_uchardet", "zlib": "$v_zlib"},
       "dep_commits": {"ffmpeg": "$v_ffmpeg_commit", "libplacebo": "$v_libplacebo_commit",
                       "libass": "$v_libass_commit", "harfbuzz": "$v_harfbuzz_commit",
                       "freetype": "$v_freetype_commit", "fribidi": "$v_fribidi_commit",
                       "libxml2": "$v_libxml2_commit", "dav1d": "$v_dav1d_commit"},
       # every patch applied to a dependency, by sha256: the Darwin build must
       # carry byte-identical copies of the shared FFmpeg TLS patches
       "patches": {p["file"]: p["sha256"] for p in sources["patches"]},
       "sources": [{k: e[k] for k in ("file", "id", "version", "license", "sha256", "size")}
                   for e in sources["sources"]],
       # linked from the NDK as it is, no source archive here, per binary and
       # ABI; and each binary's NDK, compilers and export count
       # (static-system.py)
       "static_system": sources.get("static_system", []),
       "binaries": sources.get("binaries", {}),
       "jar_entry_prefix": "lib/{abi}/", "abis": {}}
def elf(data, name):
    so = f"artifacts/plynic/{name}"
    open(so, "wb").write(data)
    build_id = next((l.split()[-1] for l in readelf("-n", so).splitlines() if "Build ID" in l), "")
    needed = re.findall(r"\(NEEDED\)\s+Shared library: \[(.+?)\]", readelf("-d", so))
    os.remove(so)
    return build_id, needed
for abi in abis:
    jar_path = f"artifacts/plynic/plynic-{abi}.jar"
    jar = open(jar_path, "rb").read()
    with zipfile.ZipFile(jar_path) as z:
        libmpv = z.read(f"lib/{abi}/libmpv.so")
        helper = z.read(f"lib/{abi}/libmediakitandroidhelper.so")
    build_id, needed = elf(libmpv, f"libmpv-{abi}.so")
    helper_build_id, helper_needed = elf(helper, f"helper-{abi}.so")
    out["abis"][abi] = {"jar": digests(jar), "libmpv": digests(libmpv), "build_id": build_id,
                        "needed": needed,
                        "helper": dict(digests(helper), build_id=helper_build_id, needed=helper_needed)}
json.dump(out, open("artifacts/plynic/manifest.json", "w"), indent=2)
print(json.dumps(out, indent=2))
PY

(cd artifacts/plynic && md5sum *.jar *.zip manifest.json && cat sources/SHA256SUMS)
