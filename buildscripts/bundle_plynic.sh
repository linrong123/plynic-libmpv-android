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
#     only the unstripped file turns that into a function and a line.
set -euxo pipefail
cd "$(dirname "$0")"

rm -rf deps prefix artifacts
./download.sh
./patch.sh

cp flavors/plynic.sh scripts/ffmpeg.sh
chmod +x scripts/*.sh

./build.sh

. ./include/depinfo.sh
ndk_bin=$(echo "$PWD/sdk/android-sdk-linux/ndk/$v_ndk/toolchains/llvm/prebuilt/"*)/bin
abis=(arm64-v8a armeabi-v7a x86 x86_64)

# Unstripped copies first; the jars get the stripped ones.
mkdir -p artifacts/plynic/symbols
for abi in "${abis[@]}"; do
  mkdir -p "artifacts/plynic/symbols/$abi"
  cp "prefix/$abi/usr/local/lib/libmpv.so" "artifacts/plynic/symbols/$abi/libmpv.so"
  "$ndk_bin/llvm-strip" --strip-all "prefix/$abi/usr/local/lib/libmpv.so"
done
(cd artifacts/plynic && zip -qr debug-symbols-plynic.zip symbols && rm -rf symbols)

# The helper APK provides the other .so files of the jar (media-kit's
# android helper); libmpv.so is swapped in, exactly as bundle_full.sh does.
pushd deps/media-kit-android-helper
chmod +x gradlew
./gradlew assembleRelease
unzip -o app/build/outputs/apk/release/app-release.apk -d app/build/outputs/apk/release
for abi in "${abis[@]}"; do
  cp "../../prefix/$abi/usr/local/lib/libmpv.so" "app/build/outputs/apk/release/lib/$abi/"
done
pushd app/build/outputs/apk/release
for abi in "${abis[@]}"; do
  rm -f "plynic-$abi.jar"
  zip -r "plynic-$abi.jar" "lib/$abi/"*.so
done
popd
popd
cp deps/media-kit-android-helper/app/build/outputs/apk/release/plynic-*.jar artifacts/plynic/

# manifest.json: the numbers the app's lock file pins.
python3 - "$v_mpv" "$v_mpv_repo" "$v_ndk" "$v_ffmpeg" "$v_libass" "$v_harfbuzz" "$v_freetype" "$v_fribidi" "$v_libxml2" "$v_mbedtls" "$v_dav1d" "$ndk_bin" "${abis[@]}" <<'PY'
import hashlib, json, os, subprocess, sys, zipfile
mpv, mpv_repo, ndk, ffmpeg, libass, harfbuzz, freetype, fribidi, libxml2, mbedtls, dav1d, ndk_bin = sys.argv[1:13]
abis = sys.argv[13:]
def digests(data):
    return {"md5": hashlib.md5(data).hexdigest(), "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
out = {"flavor": "plynic", "tag": os.environ.get("PLYNIC_TAG", ""), "mpv_commit": mpv, "mpv_repo": mpv_repo, "ndk": ndk,
       "deps": {"ffmpeg": ffmpeg, "libass": libass, "harfbuzz": harfbuzz, "freetype": freetype.replace("-", "."),
                "fribidi": fribidi, "libxml2": libxml2, "mbedtls": mbedtls, "dav1d": dav1d},
       "jar_entry_prefix": "lib/{abi}/", "abis": {}}
for abi in abis:
    jar_path = f"artifacts/plynic/plynic-{abi}.jar"
    jar = open(jar_path, "rb").read()
    with zipfile.ZipFile(jar_path) as z:
        libmpv = z.read(f"lib/{abi}/libmpv.so")
    bid = subprocess.run([f"{ndk_bin}/llvm-readelf", "-n", f"prefix/{abi}/usr/local/lib/libmpv.so"], capture_output=True, text=True).stdout
    build_id = next((l.split()[-1] for l in bid.splitlines() if "Build ID" in l), "")
    out["abis"][abi] = {"jar": digests(jar), "libmpv": digests(libmpv), "build_id": build_id}
json.dump(out, open("artifacts/plynic/manifest.json", "w"), indent=2)
print(json.dumps(out, indent=2))
PY

(cd artifacts/plynic && md5sum *.jar *.zip manifest.json)
