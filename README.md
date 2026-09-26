# plynic-libmpv-android

Android `libmpv.so` builds for [plynic](https://github.com/linrong123/plynic),
forked from [media-kit/libmpv-android-video-build](https://github.com/media-kit/libmpv-android-video-build) v1.1.11.

Branches: `plynic/v0.41` builds mpv 0.41 with FFmpeg 8.1 (tags
`v0.41.0-plynic.<n>`); `plynic/v1.1.11` is frozen and is what the 0.36-era
`v1.1.11-plynic.1` … `.7` were built from, the rollback baseline.

A pushed tag is never moved or deleted, even when its CI run fails before
publishing anything: the fix goes out under the next number, so a tag the
app's lock names always means one build.

The iOS/macOS counterpart is
[plynic-libmpv-darwin](https://github.com/linrong123/plynic-libmpv-darwin):
same plynic-mpv commit, same FFmpeg commit, byte-identical
`buildscripts/patches/ffmpeg/` (its `patches/ffmpeg/`, same keys and sha256
in both manifests), same dependency versions, and the same tag for a pair
of builds. Each platform has FFmpeg patches of its own besides:
`buildscripts/patches/ffmpeg-android/` here, `patches/ffmpeg-darwin/` there.

What differs from upstream:

- **`plynic` flavor** (`buildscripts/flavors/plynic.sh`): upstream `full` without
  `--disable-swscale-alpha` (scaled PGS subtitles came out with opaque black
  boxes), with the spdif muxer, and without FFmpeg 8's MediaCodec *audio*
  decoders.
- **mpv from [plynic-mpv](https://github.com/linrong123/plynic-mpv)** at a pinned
  commit (`buildscripts/include/depinfo.sh`: `v_mpv`, `v_mpv_repo`): upstream
  `v0.41.0` plus upstream fixes and a small patch stack (an Android VO that
  draws OSD/subtitles into a second Surface, a JavaVM hook, `ao_audiotrack`
  fixes, the Android clock), listed in the plynic-mpv README.
- **FFmpeg patches** (`buildscripts/patches/ffmpeg/`, applied in file name
  order):
  - `tls_mbedtls_ca_partial.patch`: a CA file in which some certificates
    cannot be parsed is used with the others and a warning instead of failing;
  - `tls_mbedtls_no_ip_sni.patch`: an IP address goes into the TLS SNI
    extension only when the certificate is verified (mbedtls then needs it as
    the hostname for the iPAddress subjectAltName check); without
    verification it is left out, as RFC 6066 wants and as FFmpeg's OpenSSL and
    GnuTLS backends do;
  - `tls_mbedtls_verify_flags.patch`: a rejected server certificate is logged
    with the reasons (format below);
  - `upstream_http_*.patch`: FFmpeg's own fixes from master, not yet on the
    8.1 branch (see v0.41.0-plynic.rc1 below);
  - Android only, `buildscripts/patches/ffmpeg-android/` (applied after
    them): `mediacodecdec_rotation.patch`, a `rotation` option for the
    MediaCodec video decoders, which MediaCodec takes as `KEY_ROTATION` and
    turns what it renders to a surface by (since rc7, see below).
- **`--build-id=sha1`** on libmpv.so, so a native crash can be attributed to a
  build and symbolized against the release's `debug-symbols-plynic.zip`.
- **`mpv-version` says which fork commit it is**: `mpv v0.41.0-plynic-g<first
  9 hex digits of v_mpv>` (`scripts/mpv.sh`), the same string the Darwin build
  stamps, instead of `git describe`.
- **Subtitle charset detection**: mpv is built with iconv (GNU libiconv) and
  uchardet, so `sub-codepage=auto` turns GBK / Big5 / Shift_JIS / CP1251 …
  external subtitles into UTF-8 instead of Latin-1 mojibake.
- **libmpv.so is linked with `--no-undefined`**: every dynamic import must
  resolve against the NDK stubs at link time, because a libmpv.so with an
  unresolved symbol does not load at all on Android.
- **Nothing of the C++ runtime is exported**: libplacebo needs the NDK's static
  libc++, which is linked in and hidden (`--exclude-libs`), as are libplacebo,
  libiconv, uchardet and zlib themselves, and compiler-rt's builtins (since rc4:
  rc1-rc3 exported their `__emutls_get_address`). The build checks it: it
  fails when libmpv.so exports a single definition of one of those archives
  (for the pinned dependencies since rc6, see
  [Corresponding source](#corresponding-source)). The only `__` names
  libmpv.so exports are libxml2's `__xml*`. `DT_NEEDED` is `libm libandroid
  libmediandk libdl libOpenSLES libEGL libc`; a `libc++_shared.so` there would
  keep libmpv.so from loading (the app does not ship one). The jar's other
  library, `libmediakitandroidhelper.so` (media-kit-android-helper, unchanged
  source), is built with the same NDK and exports only its own API, 12
  symbols (since rc5, see below).
- **zlib is built here** from its signed release tarball (`scripts/zlib.sh`,
  since rc5), not taken from the NDK sysroot, so every library in libmpv.so
  has a pinned, published source.
- **Every dependency is pinned**: git sources by tag *and* commit
  (`download-deps.sh` refuses a moved tag), tarballs by SHA-256.
- **The complete corresponding source is published with every release**
  (`buildscripts/collect-sources.sh`, see below).
- CI (`.github/workflows/plynic.yaml`): a tag `v<base>-plynic.<n>` builds the
  four ABIs and attaches `plynic-<abi>.jar`, `manifest.json` (digests, sizes,
  build-ids, `DT_NEEDED`, dependency versions and commits, patch digests,
  sources), `debug-symbols-plynic.zip` (per ABI both libraries of the jar,
  unstripped, with the jar's build-ids; the helper since rc6) and
  `sources/*` to the release; a tag `v<base>-plynic.rc<n>` is published as a
  prerelease.

## Log lines for embedders

FFmpeg's `tls_mbedtls` messages that an embedder may parse. Through libmpv
they arrive as log messages with prefix `ffmpeg`; the text starts with the
URL protocol's name, `tls: ` (also for the TLS connection under an
`https://` URL or an HLS segment).

**Server certificate rejected** (`tls_verify=1`): the first `error` line is
plynic's, FFmpeg's own follow it:

```
tls: tls_mbedtls: certificate verify failed: flags=0x5 (BADCERT_EXPIRED|BADCERT_CN_MISMATCH)
tls: mbedtls_ssl_get_verify_result reported problems with the certificate verification, returned flags: 5
```

- FFmpeg's lines are **not stable across versions**, key on the first one.
  FFmpeg 8.1 completes the handshake with mbedtls's `VERIFY_OPTIONAL` and
  checks the result afterwards, so its line is `mbedtls_ssl_get_verify_result
  reported problems with the certificate verification, returned flags: <n>`
  (decimal), followed by `The certificate is not correctly signed by the
  trusted CA.` when `BADCERT_NOT_TRUSTED` is set. FFmpeg 6.0
  (`v1.1.11-plynic.*`) printed `mbedtls_ssl_handshake returned -0x2700`
  instead. `Certificate verification failed.`, which FFmpeg 8.1 has for a
  handshake that fails with `MBEDTLS_ERR_X509_CERT_VERIFY_FAILED`, does not
  occur with that setup (the flags line precedes it if it ever does).
- `flags` is `mbedtls_ssl_get_verify_result()` in lowercase hex, no padding.
  Regular expression for the first line:
  `^tls: tls_mbedtls: certificate verify failed: flags=0x([0-9a-f]+) \(([A-Z0-9_|]*)\)$`
- In the parentheses: the name of each set flag, as mbedtls names it
  (`MBEDTLS_X509_CRT_ERROR_INFO_LIST`, the table
  `mbedtls_x509_crt_verify_info()` prints from) without the `MBEDTLS_X509_`
  prefix, joined by `|`, in that table's order (increasing bit value in
  mbedtls 3.6). Bits without a name are only in `flags`, so the list may be
  empty. The names a player will see:

  | Name | Bit | Meaning |
  |---|---|---|
  | `BADCERT_EXPIRED` | `0x1` | validity has ended (or the device clock is ahead) |
  | `BADCERT_FUTURE` | `0x200` | validity has not started (or the device clock is behind) |
  | `BADCERT_CN_MISMATCH` | `0x4` | the host (name or IP address) is not in the certificate |
  | `BADCERT_NOT_TRUSTED` | `0x8` | no chain to a CA of `ca_file` (untrusted issuer, missing intermediate, self-signed) |
  | `BADCERT_KEY_USAGE`, `BADCERT_EXT_KEY_USAGE`, `BADCERT_NS_CERT_TYPE` | `0x800`, `0x1000`, `0x2000` | not a TLS server certificate |
  | `BADCERT_BAD_MD`, `BADCERT_BAD_PK`, `BADCERT_BAD_KEY` | `0x4000`, `0x8000`, `0x10000` | signed with a hash, algorithm or key size mbedtls does not accept |

  The others do not occur here: `BADCERT_REVOKED` and `BADCRL_*` need CRLs,
  `BADCERT_MISSING`, `BADCERT_SKIP_VERIFY` and `BADCERT_OTHER` client
  certificates or a verify callback, none of which FFmpeg sets up.
- Several reasons can be set at once (above: expired and for another host).
  Checked against mbedtls 3.6.7 over TLS 1.3 and TLS 1.2.

**Rotation** (`video-rotate`, or the rotation a file carries): mpv rotates in
the VO when the VO can (`vo=gpu` and the render API's OpenGL backend, every
multiple of 90 degrees) and otherwise asks lavfi for its `rotate` filter,
which this build does not have (the flavor keeps two FFmpeg filters,
overlay and equalizer). A rotated frame that reaches a VO that cannot rotate
logs

```
lavfi: filter 'rotate' not found or failed to allocate     (fatal)
autorotate: Creating filter 'rotate' failed.                (error)
autorotate: could not create rotation filter                (error)
```

and passes on unrotated. The VO that does this is `vo=null`: media_kit's
Android texture writes it while it has no Surface and first when the
Surface changes (`vo=null`, `android-surface-size`, `wid`, `vo`), so a
rotated video whose track stays selected across the change logs those lines
once, and the VO that follows shows it rotated as it should; parking the
track first (`vid=no` ... `vid=auto`) avoids them. Nothing is lost: vo=null
throws the frames away. The render API's software backend (not used on
Android) draws rotated frames unrotated since rc6.

MediaCodec surface frames (`vo=mediacodec_embed`, `vo=mediacodec_osd`)
cannot be rotated in software at all. Since rc7 MediaCodec rotates them:
the decoder is configured with the rotation (`KEY_ROTATION`) and every
buffer it renders carries it as its transform, which the compositor applies.
The rotation is the stream's plus `video-rotate` (multiples of 90 degrees),
and a verbose line says so:

```
vd: Decoder rotates the video by 90 degrees.
```

What mpv reports stays as it was: `video-params` and `video-out-params`
have the decoded size and `rotate`, as with `vo=gpu`, so an embedder sizes
the Surface for the rotated picture (swapping `dw` and `dh` for 90 and 270)
and MediaCodec scales the turned picture to fill it; the OSD VO draws
subtitles and the OSD upright into `vo-mediacodec-osd-video-rect`, laid out
for the rotated picture. Nothing needs to turn the SurfaceView (an Android
SurfaceView ignores view transforms anyway). MediaCodec takes the rotation
only when it is configured, so a new `video-rotate` makes a new decoder
(`vd: Rotation changed, reinitializing the decoder.`), which resumes at the
next keyframe. rc6 and earlier logged `autorotate: Video rotation with this
format not supported` (error) and the VO's `Video is flagged as rotated by
90 degrees, but the video output does not support this.` (warning), and
showed the picture as decoded: sideways, and stretched into a Surface sized
for the rotated picture. `tools/rotate-check` checks all of it on a device.

**CA file**: `tls: mbedtls_x509_crt_parse_file for CA cert returned <n>`
(`error`: `n` < 0, or not a single certificate could be parsed; the same in
FFmpeg 6.0 and 8.1) and `tls: Skipped <n> certificate(s) of the CA file that
could not be parsed, <m> loaded` (`warning`), see
`tls_mbedtls_ca_partial.patch`.

## Dependencies

Everything below is linked statically into `libmpv.so`. Versions are pinned in
`buildscripts/include/depinfo.sh` (git sources by tag and commit, tarballs by
SHA-256) and published in each release's `manifest.json` under `deps` and
`dep_commits`.

| Library | Version | Licence (as used here) | Notes |
|---|---|---|---|
| mpv (plynic-mpv) | `v_mpv` commit | LGPL-2.1-or-later | `-Dgpl=false` |
| FFmpeg | 8.1.3 (`1041abdc96`) | LGPL-3.0-or-later | `--disable-gpl --enable-version3`; version 3 is what lets it link mbedtls's Apache-2.0 code. `--disable-iconv` on purpose, see the flavor file |
| libplacebo | 7.360.1 | LGPL-2.1-or-later | OpenGL (ES) only: no Vulkan, LittleCMS, Dolby Vision. Its submodules: glad (MIT; the GL loader it generates is (WTFPL OR CC0-1.0) AND Apache-2.0), fast_float (Apache-2.0 OR MIT OR BSL-1.0), Vulkan-Headers (headers only); jinja/markupsafe only run at build time |
| mbedtls | 3.6.7 (LTS) | Apache-2.0 (dual Apache-2.0 / GPL-2.0-or-later) | release tarball (a git checkout of the tag lacks `framework/`); `MBEDTLS_PLATFORM_DEV_RANDOM="/dev/urandom"`, `MBEDTLS_THREADING_C` + `_PTHREAD`, see `scripts/mbedtls.sh` |
| dav1d | 1.5.4 | BSD-2-Clause | |
| libxml2 | 2.14.6 | MIT | |
| libass | 0.17.5 | ISC | with its NEON (aarch64) and SSE2/AVX2 (x86, x86_64) assembly |
| FreeType | 2.13.3 | FreeType License (dual FTL / GPL-2.0) | |
| FriBidi | 1.0.17 | LGPL-2.1-or-later | |
| HarfBuzz | 11.5.1 | MIT ("Old MIT") | |
| GNU libiconv | 1.19 | LGPL-2.1-or-later | the library only; the GPL-3.0 `iconv` program and its gnulib are never built. Default encoding set (no `--enable-extra-encodings`) |
| uchardet | 0.0.8 | LGPL-2.1-or-later (tri-licensed MPL-1.1 / GPL-2.0-or-later / LGPL-2.1-or-later) | C++ without exceptions/RTTI |
| zlib | 1.3.2 | Zlib | release tarball (signed by Mark Adler, key `5ED46A67 21D36558 7791E2AA 783FCD8E 58BCAFBA`), `libz.a` only; FFmpeg (PNG, compressed MKV tracks, HTTP gzip), FreeType (gzip fonts) and mpv (MKV header compression) use it; hidden. rc1-rc4 and plynic.7 linked the NDK sysroot's `libz.a` (1.2.12 with AOSP's changes) and exported its API |
| LLVM libc++ / libc++abi / libunwind, compiler-rt builtins (NDK r25c, clang 14.0.7, static) | — | Apache-2.0 WITH LLVM-exception | for libplacebo's C++ parts and uchardet's `operator new`/`delete`, and what the compiler calls (emulated TLS, integer and float helpers); hidden. From the NDK as it is, not built here. The helper links the same runtime, also hidden |

`libmediakitandroidhelper.so`, the jar's second library, is
[media-kit-android-helper](https://github.com/media-kit/media-kit-android-helper)
at `v_mkhelper_commit` (MIT), built by its own Gradle project as it is. What
plynic changes comes from outside its tree (`bundle_plynic.sh` passes
`include/helper.init.gradle` and `include/helper.cmake`): the NDK is
`v_ndk` (the Android Gradle Plugin's default was NDK r26 up to rc4), its
code is compiled with `-fvisibility=hidden` and linked with
`--exclude-libs,ALL`, so it exports its 7 `MediaKitAndroidHelper*` functions
and 5 JNI natives and nothing of the static C++ runtime, and lld writes its
archive statistics for `static_system`.

The build scripts themselves are MIT (see `LICENSE`). The plynic patches to
mpv are published under mpv's terms in the plynic-mpv repository, the FFmpeg
patches under FFmpeg's.

## Corresponding source

Every release built by the workflow carries, next to the jars, the complete
source its `libmpv.so` was built from (`buildscripts/collect-sources.sh`):
one archive per dependency at the pinned commit (`git archive`, submodules
included) or the upstream release tarball itself (same SHA-256 as upstream's),
the plynic-mpv tree at `v_mpv`, the patches, media-kit-android-helper (the
jar's other `.so` file), this repository at the tagged commit,
`SOURCES.json` (version, licence, upstream location and commit or digest,
SHA-256, patches of each file) and `SHA256SUMS`. `manifest.json` lists the
same files.

What the jar's two libraries link from the NDK as it is - the LLVM runtime
in the table above - has no archive here: it is the NDK's own code, whose
source AOSP publishes. SOURCES.json and `manifest.json` record it under
`static_system` (since rc4; per binary since rc5): per component the
version, licence, the NDK revision it came with, where its source is (AOSP
`toolchain/llvm-project` at the commit the NDK's manifest names, and the
upstream LLVM commit that is based on), whether anything of it is exported,
and per binary (`libmpv.so`, `libmediakitandroidhelper.so`) and ABI each
archive's path in the NDK, SHA-256, how many members lld took and how many
of its definitions the binary exports (counted in its dynamic symbol table).
`binaries` records per binary and ABI the NDK, the compilers its `.comment`
section names, the linker and the number of exported symbols, and (since
rc6) under `prefix` each archive of the build prefix that libmpv.so takes
code from: the dependency it is built from, whether libmpv.so hides it
(zlib, libiconv, uchardet, libplacebo: `--exclude-libs` in `scripts/mpv.sh`)
and how many of its members were taken and of its definitions are exported;
the SOURCES.json entry of each hidden dependency has the same numbers under
`hidden_in`.
`include/static-system.py` writes both after the build from lld's
`--print-archive-stats` (`scripts/mpv.sh`, `include/helper.cmake`) and the
binaries themselves, and fails the build when lld takes code from an NDK
archive other than those (the sysroot's `libz.a` included), when a binary
exports any of it, when libmpv.so exports any definition of a hidden
dependency, does not link one (renamed, moved, no longer static) or takes
code from a prefix archive the script does not classify, or when a binary
was compiled or linked by another clang than the NDK's.
For a local release: `collect-sources.sh <dir>`, the build, the helper
(`bundle_plynic.sh` has the Gradle line), then `include/static-system.py
<dir> sdk/android-sdk-linux/ndk/<v_ndk> prefix/<abi>/libmpv.archive-stats.tsv=prefix/<abi>/lib/libmpv.so
prefix/<abi>/libmediakitandroidhelper.archive-stats.tsv=<apk>/lib/<abi>/libmediakitandroidhelper.so ...`.

Retention: a release that any published plynic version pinned is never
deleted, and its source stays available for at least three years after that
plynic version was last distributed.

## Reproducibility

Every input is pinned (`include/depinfo.sh`: the fork's commit, git
sources by tag and commit, tarballs by SHA-256, the NDK and meson
versions), so a tag always builds the same source with the same flags. The
binaries are byte-for-byte the same with one known exception:

- Two builds on the same host at the same path give byte-identical
  `libmpv.so` for every ABI (checked on macOS, rc2).
- Between two CI runs (fresh runners, everything rebuilt, no cache),
  arm64-v8a, armeabi-v7a and x86 came out byte-identical, **x86_64 did
  not**. The two runs compared were rc6's pre-run (`workflow_dispatch` on
  `0c2cab4`) and its tag run (`cb61e32`, which only changes README.md), so
  different commits of this repository with the same build inputs. The
  x86_64 libraries differ in one function, HarfBuzz's
  `AAT::LigatureSubtable<ObsoleteTypes>::driver_context_t::transition`
  (325 bytes of `.text`), and so in their GNU build-id: NDK r25c's clang
  14.0.7 does not generate that function deterministically for x86_64.

So an x86_64 `libmpv.so` rebuilt from a tag may differ from the released one
in that function and its build-id; a comparison of two builds has to allow
for it (compare the other three ABIs byte for byte, and for x86_64 look at
what the difference touches). The app pins each ABI by the SHA-256 and
build-id in the release's `manifest.json`, so what it ships is always the
released binary, and `debug-symbols-plynic.zip` symbolizes exactly that one.

## Releases

### v0.41.0-plynic.rc7

rc7 = rc6 + portrait videos upright on the MediaCodec surface VOs
(prerelease, not pinned by the app). The dependencies, the flavor and the
helper are unchanged; FFmpeg gets one Android-only patch.

- **mpv: plynic-mpv `4c4e802343` → `f7a734caa2`**: `vo_mediacodec_embed,
  vo_mediacodec_osd: rotate in MediaCodec` (`5bb084fe55`) and its README
  note. A video whose file says to turn it by 90 or 270 degrees (a phone's
  portrait video) played sideways on `vo=mediacodec_embed` and
  `vo=mediacodec_osd`, stretched into a Surface an app sizes for the
  rotated picture: MediaCodec renders straight into that Surface, nothing
  in mpv sees the pixels, and an Android SurfaceView cannot be turned by the
  app either. Both VOs now declare `VO_CAP_DECODER_ROTATE` (with
  `VO_CAP_ROTATE90`), and vd_lavc gives the MediaCodec decoder the rotation
  mpv reports for those frames (the stream's plus `video-rotate`), which
  MediaCodec applies as `KEY_ROTATION`: every buffer it renders carries it
  as its transform and the compositor turns it. `video-params` and
  `video-out-params` report what they did before (the decoded size and
  `rotate`); see [Log lines for embedders](#log-lines-for-embedders),
  Rotation. `vo=gpu` (the texture path, with MediaCodec into mpv's own
  AImageReader or decoding in software) is unchanged and still rotates in
  the VO.
- **FFmpeg: `buildscripts/patches/ffmpeg-android/mediacodecdec_rotation.patch`**
  (new, Android only): a `rotation` option for FFmpeg's MediaCodec video
  decoders (0, 90, 180, 270), set as `rotation-degrees` in the MediaFormat
  they configure; FFmpeg builds that MediaFormat itself and had no way for a
  caller to set it. `patch.sh` applies `patches/<dep>-android/` after
  `patches/<dep>/`; SOURCES.json lists it with FFmpeg's patches, the patch
  archive and `manifest.json`'s `patches` have it as
  `patches/ffmpeg-android/mediacodecdec_rotation.patch`. The shared
  `patches/ffmpeg/` is unchanged and still byte-identical with
  plynic-libmpv-darwin's. A consumer that expects every Android patch under
  `patches/ffmpeg/` has to allow the new directory.
- **libmpv.so vs rc6** (local arm64 build against rc6's release): the same
  9033 exports and `DT_NEEDED`; +2 KB (vd_lavc, the decoder option) and the
  version stamp (`-gf7a734caa`).
- **`tools/rotate-check`** checks it: the embed case reads the buffer
  transform MediaCodec gives each frame (`Image.getTransform()`, T4 for 90
  degrees clockwise) while `video-rotate` goes 90, 180, 270, 0 (a new
  decoder each time), `embed-meta` and `osd` play a VP9 file whose own
  rotation is 270 degrees (new `rot_vp9_meta90.webm`), and `gpu-mc` (new)
  checks that the texture path with MediaCodec decoding still turns the
  picture once. On the Android 14 TV emulator a local arm64 build of this
  commit passes 9 of 9; rc6 fails `embed`, `embed-meta` and `osd` (T0,
  "Video rotation with this format not supported").
- **Checked in the app** (a dev build with the local arm64 engine, Android
  14 TV emulator, VP9 in MKV and MP4 with a display matrix of 90 and 270
  degrees and a landscape control, with an ASS track): on `mediacodec_osd`
  and `mediacodec_embed` the picture is upright and pillarboxed
  (SurfaceFlinger: the video layer's `bufferTransform` ROT_90 / ROT_270,
  display frame 608x1080 in the middle; the screen capture shows the
  quadrants upright), the OSD VO's subtitles upright at the top and bottom
  of the portrait picture, the landscape control unchanged (transform 0,
  full screen); switching between the two VOs mid-file keeps it upright.
  `tools/osd-check` (keep-out under both names, 20 of 20 paused switches)
  passes as on rc6.
- **README**: [Reproducibility](#reproducibility) (new): what "the same
  engine" means across builds, and the x86_64 HarfBuzz function that NDK
  r25c's clang does not generate deterministically.

### v0.41.0-plynic.rc6

rc6 = rc5 + an upstream fix both platforms build + checks on what rc5
recorded by hand (prerelease, not pinned by the app). FFmpeg, the
dependencies, the flavor and the helper are unchanged.

- **mpv: plynic-mpv `d75b92b584` → `4c4e802343`**: `vo_libmpv: use the
  VO_CAP of the renderer backend instead of the VO` (upstream `7a94ec5719`,
  cherry-picked). vo_libmpv announced `VO_CAP_ROTATE90` for every render API
  backend and computed a rotated source rectangle for the software backend
  too, which cannot rotate: the first frame rotated by 90 or 270 degrees (a
  file with that rotation, `video-rotate=90`) aborted the process on an
  assertion in `mp_image_crop()`. That backend is media_kit_video's on iOS
  (the simulator, a device without its OpenGL texture), where rc5 aborted on
  every portrait phone video; with the fix it draws such frames unrotated.
  Android renders through `vo=gpu` and the MediaCodec VOs, not the render
  API: the code runs here only if an embedder uses the software backend.
- **Rotation needs no FFmpeg filter** (the rc5 app smoke saw `filter
  'rotate' not found` with `video-rotate=90` on the texture path, and the
  picture turned correctly). mpv rotates in the VO when the VO can and asks
  lavfi for `rotate` otherwise; the only VO in the app's paths that gets
  there is media_kit's `vo=null` placeholder, whose frames are thrown away,
  and MediaCodec surface frames cannot be rotated in software whatever
  FFmpeg has. Enabling `rotate` would only make a rotated file's frames go
  through a CPU rotation while `vo=null` holds them. The flavor stays as it
  is; the log lines and when they appear are under
  [Log lines for embedders](#log-lines-for-embedders). `tools/rotate-check`
  (new) checks it over adb: `vo=gpu` into a Surface shows `video-rotate`
  0/90/180/270 and a file's display-matrix rotation correctly (each frame
  read back), `vo=null` logs the missing filter, media_kit's Surface change
  order logs it once while the picture stays right, the order that parks
  the track first does not, and `vo=mediacodec_embed` reports that MediaCodec
  frames cannot be rotated. rc5 and rc6 give the same results.
- **The hidden dependencies are checked**: rc5 hid zlib (and before it
  libiconv, uchardet, libplacebo) with `--exclude-libs`, but
  `static-system.py` skipped the build prefix, so "hidden" in SOURCES.json
  was not checked by anything. The build now fails when libmpv.so exports a
  single definition of a hidden archive, does not link one, or links a
  prefix archive nobody classified; `binaries.libmpv.so.<abi>.prefix` and
  each hidden dependency's `hidden_in` in SOURCES.json have the measured
  numbers (0 exported for all four, every ABI). A test build with `libz.a`
  left out of `--exclude-libs` fails with 57 exported zlib definitions.
- **debug-symbols-plynic.zip has the helper**: per ABI the unstripped
  `libmediakitandroidhelper.so` next to `libmpv.so`, found by the build-id
  of the jar's stripped copy; the build fails when a file is missing or its
  build-id is not the jar's (manifest.json's `build_id`, `helper.build_id`).
- **Correction to rc5's notes**: the helper sizes there were a local
  build's; the release's are armeabi-v7a 104 764 and x86 199 772 bytes (local
  104 780, 199 788), arm64 and x86_64 the same (fixed above). The README
  said "the jar's other `.so` files"; it has one.
- **libmpv.so vs rc5** (CI builds): the same size on every ABI (arm64 19 797
  368, armeabi-v7a 18 538 800, x86 20 429 116, x86_64 23 687 800 bytes),
  the same exports (9033, 8636, 7731, 8153) and `DT_NEEDED`; the difference
  is `vo_libmpv.c` and the version stamp (`-g4c4e80234`). The helper is
  byte-identical to rc5's.
- **Checked** on the Android 14 TV emulator and the Android 7.0 arm64
  emulator, a local build of this commit next to rc5's CI build (the
  release body says what was run on this release's own jars):
  the rc1 list (probe with `ao=null` and `ao=audiotrack`, a second instance,
  pause without flush, `mediacodec_embed`, `mediacodec_osd` with PGS/ASS,
  `vo=gpu` static and switched at run time, GBK/Big5/CP1251 detection),
  the 23-case TLS matrix (verdicts, TLS log lines, SNI and handshakes the
  same as rc5's on both), `tools/osd-check` (keep-out under both names, 20
  of 20 paused switches), `tools/rotate-check` (6 of 6), `screenshot-raw`
  (software frames in bgr0 and rgba64; MediaCodec surface frames fail, as
  always), a PNG `screenshot-to-file` (compression 9) decoded back by
  FFmpeg's PNG decoder and read back from a Surface with the right colours,
  and the helper in an `app_process` harness (JNI natives, the asset copy
  through a stand-in Context, the 7 C functions through `dlsym`,
  `OpenFileDescriptor` calling back into Java).

### v0.41.0-plynic.rc5

rc5 = rc4 with the jar's second library and zlib under the same rules as
everything else in it (prerelease, not pinned by the app). mpv (plynic-mpv
`d75b92b584`, as rc4), FFmpeg, the other dependencies and the flavor's
features are unchanged.

- **zlib 1.3.2, built here** (`scripts/zlib.sh`; the release tarball, pinned
  by SHA-256, signed by Mark Adler) instead of the NDK sysroot's `libz.a`:
  1.2.12 with AOSP's changes, compiled by the platform build's clang 15.0.1,
  with no revision in the NDK to say which source it was. Its source is in
  `sources/` (`zlib-1.3.2.tar.xz`, byte-identical with upstream's).
  FFmpeg (`--enable-zlib`, autodetected before), FreeType (`-Dzlib=system`)
  and mpv (`-Dzlib=enabled`) now fail to configure without it.
- **zlib is hidden in libmpv.so**: against rc4 each ABI exports exactly
  zlib's 53 API names fewer (`inflate*`, `deflate*`, `crc32*`, `adler32*`,
  `compress`-family, `zlibVersion`, ...) and nothing else changes: arm64
  9086 → 9033, armeabi-v7a 8689 → 8636, x86 7784 → 7731, x86_64 8206 → 8153.
  `DT_NEEDED` unchanged. Anything that called zlib through libmpv.so (the
  app does not) has to bring its own.
- **libmediakitandroidhelper.so** (media-kit-android-helper `42054e5`, the
  source unchanged): built with NDK r25c like libmpv.so instead of the
  Android Gradle Plugin's default r26 (clang 17.0.2), and exports 12 symbols
  (the 7 `MediaKitAndroidHelper*` functions, the 5 JNI natives) instead of
  about 700 (its static C++ runtime: `std::`, `__cxa_*`,
  `__gxx_personality_v0`, `__emutls_get_address`). Stripped, rc4 → rc5 as
  released (CI builds): arm64 386 696 → 213 936 bytes, armeabi-v7a 286 812
  → 104 764, x86 350 252 → 199 772, x86_64 367 528 → 217 696. (These notes
  gave local build sizes until rc6; like libmpv.so, the helper differs by a
  few bytes between a CI and a local build of the same commit.) See
  [Dependencies](#dependencies).
- **`static_system` per binary, exports counted**: SOURCES.json and
  manifest.json record the LLVM runtime per binary and ABI, both libraries,
  with each archive's exported definitions counted in the binary's dynamic
  symbol table (0 everywhere); new `binaries` (NDK, compilers, linker,
  export count per binary and ABI); manifest.json gets `deps.zlib` and, per
  ABI, `helper` (digests, build-id, `DT_NEEDED`). The build now fails on an
  unclassified or refused NDK archive (the sysroot's `libz.a`), on any
  exported runtime symbol, and on a binary compiled or linked by another
  clang than the NDK's.
- **Correction to rc4's notes**: rc4's `static_system` covered libmpv.so
  only (not the helper, NDK r26 with its C++ runtime exported), and its
  zlib entry named a version but no source revision; "SOURCES.json
  complete" did not hold.
- **libmpv.so vs rc4**: zlib 1.3.2 (hidden) for the NDK's 1.2.12
  (exported); the rest is the same code, and the configuration string mpv
  embeds shows the new link arguments. Stripped sizes: arm64 −5.7 KB,
  armeabi-v7a +16 KB, x86 +1 KB, x86_64 −4 KB.
- **Checked** on the Android 14 TV emulator and the Android 7.0 arm64
  emulator: the rc1 list (probe with `ao=null` and `ao=audiotrack`, a second
  instance, pause without flush, `mediacodec_embed`, `mediacodec_osd` with
  PGS/ASS, `vo=gpu` static and switched at run time, GBK/Big5/CP1251
  detection) with the same results as rc4; the 23-case TLS matrix:
  verdicts, TLS log lines, SNI and handshakes identical to rc4 on both;
  `tools/osd-check`: keep-out under both names and 20 of 20 paused
  switches pass; `screenshot-raw` as in rc4 (`mediacodec-copy` and software
  decoding return the picture, MediaCodec surface frames do not); zlib
  itself: a PNG `screenshot-to-file` (compression 9) is valid and decodes
  back through FFmpeg's PNG decoder. The helper (arm64), in an
  `app_process` harness with a stand-in Context on both emulators, rc4's
  and rc5's alike: the JNI natives,
  `setApplicationContext`, asset copy, and the 7 C functions through
  `dlsym` (JavaVM, files dir, emulator flag, API level, asset copy,
  `OpenFileDescriptor` of a `file://` URI through the Java callback, close)
  all pass; rc5 exports none of the runtime names rc4 did.

### v0.41.0-plynic.rc4

rc4 = rc3 + an upstream fix both platforms build, compiler-rt's builtins
hidden, and SOURCES.json complete (prerelease, not pinned by the app;
"complete" did not hold, see the correction under rc5).
FFmpeg, the dependencies and the flavor are unchanged.

- **mpv: plynic-mpv `c5438ee6c4` → `d75b92b584`**: `screenshot: correctly
  detect hardware frame` (upstream `c66204b69b`, cherry-picked). mpv 0.41's
  `9b1d47ece1` gives a hardware image the descriptor of its software
  sub-format, so `screenshot-raw` stopped downloading VideoToolbox frames and
  handed them to libswscale: on iOS and macOS no screenshot of a
  hardware-decoded frame through the render API. On Android nothing
  changes: MediaCodec surface frames (`hwdec=mediacodec`) have no frames
  context, so they kept the hardware descriptor, and a screenshot of them
  fails as it always has (plynic.7, rc3 and rc4 alike: the picture is in a
  Surface, there is nothing to download); with `mediacodec-copy` or software
  decoding `screenshot-raw video` returns the picture in bgr0 and rgba64 on
  rc3 and rc4 alike (TV emulator, `vo=gpu`).
- **`__emutls_get_address` is no longer exported**: compiler-rt's builtins
  archive, which the clang driver adds to every link, joins the
  `--exclude-libs` list (libc++abi's per-thread exception state is
  `thread_local`, emulated TLS below API 29). Against rc3 each ABI exports
  exactly that one symbol fewer (arm64 9087 → 9086, armeabi-v7a 8690 → 8689,
  x86 7785 → 7784, x86_64 8207 → 8206); `DT_NEEDED` is unchanged. A consumer
  that tolerated it as a known runtime export can drop that exception.
- **SOURCES.json and manifest.json: `static_system`** — zlib 1.2.12 (the NDK
  sysroot's `libz.a`), and clang 14.0.7's libc++/libc++abi, libunwind and
  builtins, with where their source is and per ABI the archives' SHA-256
  and the members lld took (see [Corresponding source](#corresponding-source)).
  `sources` and the archives keep their shape.
- **libmpv.so vs rc3**: the mpv fix, the builtins' symbols hidden, and the
  configuration string mpv embeds (it quotes the link arguments); stripped
  sizes within 2 KB of rc3 on every ABI.
- **Checked** on the Android 14 TV emulator and the Android 7.0 arm64
  emulator, the rc1 list (probe with `ao=null` and `ao=audiotrack`, a second
  instance, pause without flush, `mediacodec_embed`, `mediacodec_osd` with
  PGS/ASS, `vo=gpu` static and switched at run time, GBK/Big5/CP1251
  detection): same results as rc3; the 23-case TLS matrix: verdicts, TLS
  log lines, SNI and handshakes identical to rc3 on both; `tools/osd-check`
  on the TV emulator: keep-out under both names and 20 of 20 paused
  switches pass; the screenshots above.

### v0.41.0-plynic.rc3

rc3 = rc2 + a player fix both platforms need + a Darwin-only commit
(prerelease, not pinned by the app). FFmpeg, the dependencies and the
flavor are unchanged.

- **mpv: plynic-mpv `f226dd6356` → `c5438ee6c4`**:
  - `player: redraw when a track selected while paused gets its subtitles`
    (shared code). Selecting a subtitle track while paused showed nothing,
    or a stale line, until the next change of anything whenever the
    track's packets arrived after the one redraw that came with the switch.
    On the Android 14 TV emulator, the PGS track of an MKV selected once per
    run, paused, with sub-keepout never set: 8 of 30 runs on rc1 and 11 of
    30 on rc2 ended wrong (so not the keep-out move); 30 of 30 on the fix
    end on the right line, about 100 ms after the switch when the packets
    were late. `tools/osd-check` (below) has it as a check: rc2 8 of 20
    runs blank, rc3 0 of 20.
  - Darwin only (not compiled here): `ao_coreaudio: don't set
    kAudioOutputUnitProperty_ChannelMap` (macOS 27 refused 0.41's channel
    map for every mono file).
- **Correction to rc2's note on the old option name**:
  `--vo-mediacodec-osd-sub-keepout` is an alias of the global
  `--sub-keepout`. A value written under either name lifts the subtitles
  on **every** VO of that mpv instance — `vo=gpu`, the render API — until it
  is set back to 0; on the 0.36-era builds (plynic.7) the old name only ever
  reached the OSD VO. An app that leaves the OSD VO with the band up (for
  example falling back to `vo=gpu`) has to write 0 itself.
- **CI**: third-party actions pinned by commit; the build job only reads
  the repository and a separate job uploads the release; media-kit's
  `build.yaml` (its own flavors, encoders-gpl included, on pushes to `main`
  and on pull requests, with write access) removed.
- **libmpv.so vs rc2**: different code in `player/` (the fix; stripped
  arm64 19 804 080 → 19 804 160 bytes); `ao_coreaudio.c` is not compiled
  here.
- **Checked** on the Android 14 TV emulator and the Android 7.0 arm64
  emulator, the rc1 list: probe with `ao=null` and `ao=audiotrack`, a second
  instance, pause without flush, `mediacodec_embed`, `mediacodec_osd` with
  PGS/ASS, `vo=gpu` static and switched at run time, GBK/Big5/CP1251
  detection — same results as rc2 (the frame drops of `vo=gpu` on the
  emulator vary from run to run on rc2 and rc3 alike); the 23-case TLS
  matrix: verdicts, TLS log lines, SNI and handshakes identical to rc2 on
  both.
- **`tools/osd-check`** (new): the keep-out and paused-switch checks on
  `vo_mediacodec_osd` over adb, with a fixture made here (black VP9, an ASS
  and a PGS track): `build.sh` builds the harness, `run.sh <serial>
  <libmpv.so> <label>` runs the keep-out script under both option names
  and 20 paused switches, `judge.py` checks them (every lift clears the
  band and moves the subtitle without changing it, 0 restores it, both
  names give the same OSD at every step, every switch ends on the new
  track's subtitle). On the TV emulator: rc3 passes everything; rc2 fails
  the switches (8 of 20 blank). Needs Android 10+ (the harness), so not the
  7.0 emulator.

### v0.41.0-plynic.rc2

rc2 = rc1 + the generic subtitle keep-out band (spec 0017 T-4) + the Darwin
commits (S4.2), the commit both platforms now build (prerelease, not pinned
by the app). FFmpeg, the dependencies and the flavor are unchanged.

- **mpv: plynic-mpv `8235270d93` → `f226dd6356`**:
  - `sub: make sub-keepout a subtitle option of every VO` — the keep-out
    band moved from `vo_mediacodec_osd` into `osd_render()`, as
    `--sub-keepout` (0–50 % of the height, `UPDATE_OSD`), so it also works
    through the render API (texture path). `--vo-mediacodec-osd-sub-keepout`
    is an alias of that global option, not a VO option any more: see the
    correction under rc3 before relying on the old name.
  - Darwin only (not compiled here): `meson: enable Objective-C on every
    Darwin host`, `ao_audiounit: add --audiounit-skip-session-management`,
    `stream_file: don't ask for the file system type on iOS`.
- **Fetching**: dav1d and libplacebo fall back to their GitHub mirrors
  (`videolan/dav1d`, `haasn/libplacebo`) when code.videolan.org cannot be
  cloned; the pinned commit is checked either way, so the sources are the
  same (the first three CI runs of the rc2 tag failed on "Connection refused" from
  code.videolan.org). The encoders-gpl flavor's own dependencies (x264,
  libvpx, libvorbis, libogg, fftools-ffi) are fetched only for that flavor
  (`ENCODERS_GPL`); a plynic build never used them, and the unpinned x264
  clone was the next thing to fail.
- **libmpv.so vs a build without the Darwin commits**: identical except the
  version string and one assert message (`stream_file.c:278` → `:286`); two
  builds of the same commit are byte-identical.
- Checked on the Android 14 TV emulator and the Android 7.0 arm64 emulator,
  the same list as rc1 with the same results (probe with `ao=null` and
  `ao=audiotrack`, a second instance, pause without flush, `mediacodec_embed`,
  `mediacodec_osd` with PGS/ASS, `vo=gpu` static and switched at run time,
  GBK/Big5/CP1251 detection, the 23-case TLS matrix with the same verdicts,
  flags and SNI as rc1 on both).
- **Keep-out band on `mediacodec_osd`**: a paused script (three tracks,
  keep-out 30/45/10/0, track switches, playing with the band up, 20) gives
  the same OSD updates (bounding boxes, opaque pixel counts, average colour
  of all 17) as rc1, with either option name, and redraws within 5–20 ms
  of a change while paused, as before.
- **Known, not new** (fixed in rc3): the first redraw right after a track
  switch *while paused* races the new track's first decoded subtitle, and
  nothing redraws again until the next change: in 10 runs of that script on
  rc1 one showed an older PGS line there, in 14 on rc2 three showed none
  (until the next keep-out change); the rc1 smoke of wave 1 had the older
  line as well.

### v0.41.0-plynic.rc1

Release candidate of the move to mpv 0.41 and FFmpeg 8.1 (spec 0017 stage 3,
rc1 = rebase plus upstream fixes; published as a prerelease, not pinned by
the app).

- **mpv: plynic-mpv `ed162a9` (78d43740f5 base) → `8235270d93`** (branch
  `plynic/v0.41.0`, upstream `v0.41.0` + 10 cherry-picked upstream fixes + the
  plynic topics; details in the plynic-mpv README). Needs libplacebo now.
- **FFmpeg 6.0 → 8.1.3**, commit-verified. media-kit's `dash_base_url_escape`
  and `hls_mp4_seek` are upstream now and are dropped. The three TLS patches
  are rewritten for 8.1 (the verify-flags line now hooks the post-handshake
  check 8.1 does, see "Log lines"); `tls_mbedtls_ip_hostname.patch` shrank to
  `tls_mbedtls_no_ip_sni.patch`, since 8.1.3 itself sets the hostname for IP
  addresses (so IP-address hosts are verified against iPAddress SANs without
  a patch).
- **FFmpeg HTTP, backported from master** (`upstream_http_*.patch`, verbatim
  `git format-patch` of `f87323a359` "properly fall back on soft seek
  failure" and `bd51105806` "infer default s->willclose based on request
  header"): 8.1 reuses the connection for a seek ("soft seek") unless the
  server answered `Connection: close`, although FFmpeg itself sends
  `Connection: close` by default. A server that closes such a connection
  without echoing the header (Python's `http.server` does) made every seek
  after the first request fail with `Error reading HTTP response` and the
  file stop playing — HTTP and HTTPS alike, where FFmpeg 6.0 simply opened a
  new connection. With the backports a seek opens a new connection again (3
  connections for open + 2 seeks, as with 6.0).
- **flavor**: `--disable-postproc` and `--enable-protocol=hls` removed (both
  gone from FFmpeg 8); MediaCodec audio decoders disabled; `--enable-small`
  kept for now.
- **libplacebo 7.360.1** new (`scripts/libplacebo.sh`), with its C++ runtime
  hidden, see above.
- **mpv build**: `-Dlibplacebo=disabled` removed (no such option in 0.41);
  `audiotrack`, `opensles`, `egl-android`, `android-media-ndk` required;
  `aaudio` (new in mpv 0.38) off; version stamp.
- **`DT_NEEDED`**: `+libmediandk.so` (FFmpeg 8's MediaCodec wrapper links the
  NDK media API, API 21), `-libstdc++.so` (uchardet's `operator new/delete`
  now come from the hidden static libc++). All imports resolve against the
  API 21 NDK stubs (`--no-undefined`).
- **Exported symbols**: the 55 `mpv_*` functions are the same names and types
  as in plynic.7 on all four ABIs. FFmpeg's exports follow 8.1: 136 new
  `av*`/`sws*`/`swr*` names (arm64), and the APIs FFmpeg 8 removed are gone
  (the old channel-layout functions, the old `av_fifo_*`, `avcodec_close`,
  `av_stream_*_side_data`, `swr_alloc_set_opts`, …); the app calls none of
  them. `pl_*`, C++ runtime and `__cxa_*` symbols are not exported.
- **Dependencies pinned by commit**; **sources** published with the release.
- **meson** pinned to 1.10.0 in CI (mpv 0.41 needs >= 1.3.0).
- NDK r25c (`25.2.9519653`) builds libplacebo's C++20 as is.
- Stripped libmpv.so, plynic.7 (CI) → rc1 (local build): arm64 17.10 → 19.80
  MB, armeabi-v7a 16.31 → 18.52 MB, x86 17.85 → 20.43 MB, x86_64 20.98 →
  23.69 MB. 16 KiB `PT_LOAD` alignment and `BIND_NOW` without text
  relocations are unchanged.
- Checked on the Android 14 TV emulator (arm64) and an Android 7.0 arm64
  emulator: local files play with `ao=null` and `ao=audiotrack`; play, pause,
  seek, a second instance and EOF without errors; pausing keeps the track's
  frames (AudioFlinger: 0 flushed); `mediacodec_embed` and `mediacodec_osd`
  with VP9 through MediaCodec, PGS and ASS drawn into the OSD surface, a
  track switch, `sub-keepout` and `sub-visibility` redrawn while paused; the
  `vo=gpu` fallback (runtime switch from `mediacodec_embed`, Theora) shows
  the picture; GBK/Big5/CP1251 external subtitles detected and converted;
  the TLS matrix (TLS 1.3 and 1.2; host name and IP; expired, not yet valid,
  wrong host, untrusted, self-signed, combinations; partial and unusable CA
  files; `tls-verify=no`) gives the same verdicts and flags as plynic.7, and
  IP addresses reach the server's SNI only when verifying.

### v1.1.11-plynic.7

- **mpv: plynic-mpv `4338bc6` → `ed162a9`** (details in the plynic-mpv README):
  - **timer**: mpv's clock (`mp_raw_time_ns()`) is `CLOCK_MONOTONIC` on
    Android, the platform's time base (`System.nanoTime()`, AudioTimestamp,
    Choreographer). It was `CLOCK_MONOTONIC_RAW`, which on an arm64 3.18
    kernel (the Android 7.0 emulator) jumps back and forth by 453 s between
    calls: `mp_time_ns()` went negative and libmpv aborted in
    `mp_time_us_add()` (`time_us > 0`, or `space >= 0` in `ao/buffer.c`) as
    soon as a file was opened, so the app could not play at all there.
    Clamping would not help (time would stand still for the 453 s); other
    systems keep `CLOCK_MONOTONIC_RAW`. Checked on that emulator: local files
    play with `ao=null` and `ao=audiotrack`, and play / pause / seek / a
    second instance / EOF run without errors, where plynic.6 aborts.
  - **pause keeps the audio**: `ao_audiotrack` pauses the AudioTrack instead
    of pausing and flushing it (backports of upstream `93a924a553` "ao:
    set_pause for pull based ao" and `4d03efb4b0` "ao: don't call
    driver->set_paused after reset" let the core do that for pull AOs). Each
    pause used to throw away the 80–150 ms in the track (AudioFlinger
    reported 6112–7200 frames flushed per pause at 48 kHz), so the audio clock
    (and video with it) jumped ahead by 166–211 ms on resume, with an
    underrun warning. Now nothing is flushed: the track keeps its frames
    while paused, and on resume the audio clock is 30–37 ms past the pause
    point, without underruns (Android 14 TV emulator, 4 pauses of 1.5 s:
    audio ahead of wall time by 0.14 s in total instead of 0.71 s).
- **FFmpeg: why a certificate was rejected** (`tls_mbedtls_verify_flags.patch`)
  — with `tls_verify=1` a failed verification used to log only
  `mbedtls_ssl_handshake returned -0x2700`, the same for an expired
  certificate, one for another host and an untrusted issuer. Now one `error`
  line with mbedtls's verify flags and their names comes first, the old line
  follows unchanged:

  ```
  tls: tls_mbedtls: certificate verify failed: flags=0x4 (BADCERT_CN_MISMATCH)
  tls: mbedtls_ssl_handshake returned -0x2700
  ```

  Format, regular expression and the flag names are under "Log lines for
  embedders". Checked against mbedtls 3.6.7 over TLS 1.3 and TLS 1.2:
  `0x1` expired, `0x200` not yet valid, `0x4` host (name or IP address)
  mismatch, `0x8` untrusted issuer, and combinations (`0x5`, `0xd`). A
  certificate that passes, or a connection without `tls_verify`, logs
  neither line.
- Stripped libmpv.so, plynic.6 → plynic.7 (local build): 1.8–2.3 KB larger
  per ABI. Exported symbols, `DT_NEEDED`, 16 KiB `PT_LOAD` alignment and
  `BIND_NOW` without text relocations are unchanged.

### v1.1.11-plynic.6

- **mpv: plynic-mpv `dfd3a72` → `4338bc6`, the `ao_audiotrack` series**
  (details in the plynic-mpv README):
  - backport of upstream `46fe3cded0`: the AudioTrack JNI state is
    reference-counted, so destroying one of two mpv instances no longer
    crashes the other;
  - a direct or offloaded track (multichannel PCM, passthrough over HDMI)
    that dies on a route change is reloaded instead of being recreated and
    never started (silence, video frozen until a seek); beyond 3 reloads in
    30 s each further one backs off (1 s doubling up to 30 s);
  - no busy loop while there is nothing to write (underrun, EOF);
  - the delay no longer counts the track buffer twice before the first
    timestamp after start/seek/resume; timestamps are extrapolated in
    `CLOCK_MONOTONIC` and re-synced after a route change (speaker ↔
    Bluetooth used to leave up to 3 s of A/V offset);
  - a failed `init()` releases everything (two early returns kept the JNI
    use count up).
- **dav1d 1.2.0 → 1.5.4**: fixes CVE-2024-1580 (integer overflow, fixed in
  1.4.0). FFmpeg 6.0's libdav1d wrapper still configures (`dav1d >= 0.5.0`).
- **mbedtls 3.4.0 → 3.6.7** (3.6 LTS, supported until at least March 2027):
  the security fixes of 3.4.1 … 3.6.7 (the 2026-07 batch included). 3.6
  enables TLS 1.3 by default; FFmpeg 6.0's `tls_mbedtls` works with it because
  3.6.1+ initialises PSA crypto from the handshake and no longer surfaces
  TLS 1.3 session tickets from `mbedtls_ssl_read()`. Checked with FFmpeg 6.0 +
  this configuration against TLS 1.3-only and TLS 1.2-only servers and public
  TLS 1.3 hosts. `/dev/urandom` keeps what 3.4.0 read (3.6.6 switched the
  default to `/dev/random`, which blocks on kernels before 5.6); threading
  support makes the PSA key store safe for mpv's concurrent connections.
- **FFmpeg: `https://<IP>` with `tls_verify=1`** — FFmpeg 6.0 never set a
  hostname for an IP-address host, and since 3.6.3 mbedtls fails the
  handshake of a verifying client without one (`-0x5d80`), so every such URL
  failed. The address is now set when verifying, and mbedtls (3.5+) matches it
  against the certificate's iPAddress subjectAltNames; without `tls_verify`
  nothing changes (no SNI for addresses, no name check). The mbedtls bump and
  this patch have to ship together.
- **FFmpeg: a CA file with certificates mbedtls can't parse** (e.g. SM2 roots
  in some OEM trust stores) failed every verified connection:
  `mbedtls_x509_crt_parse_file()` returns how many it skipped, and FFmpeg took
  any non-zero value as an error. Now the others are used and FFmpeg warns
  `Skipped N certificate(s) of the CA file that could not be parsed, M loaded`.
  Only an error (< 0) or no certificate at all still fails, with the same
  `mbedtls_x509_crt_parse_file for CA cert returned …` line as before.
- **libass**: assembly enabled (was `--disable-asm` for every ABI), and it is
  now compiled with `-O2` — `CFLAGS=-fPIC` given to configure had replaced
  autoconf's `-g -O2`, so libass was built without optimisation.
- **mbedtls and libxml2 were built without optimisation too** (the same
  `CFLAGS=-fPIC` override); both now get `-O2`.
- **New: GNU libiconv 1.19 + uchardet 0.0.8**, `-Diconv=enabled
  -Duchardet=enabled` for mpv. Cost on arm64 (stripped libmpv.so): libiconv
  ≈ 0.9 MB, uchardet ≈ 0.18 MB. libmpv.so now has `DT_NEEDED libstdc++.so`
  (uchardet's operator new/delete) and is linked with `--no-undefined`.
  `libstdc++.so` is a public platform library on every API level; the
  imports carry the NDK stubs' `LIBC_O` version, which a pre-O device's
  unversioned `libstdc++.so` satisfies as a global symbol. Checked on an
  Android 7.0 (API 24) arm64 emulator: `dlopen(RTLD_NOW)` succeeds without
  linker warnings and `mpv_create()` works.
- Stripped libmpv.so, plynic.5 → plynic.6 (local build): arm64 16.32 → 17.10 MB,
  armeabi-v7a 15.52 → 16.31 MB, x86_64 20.04 → 20.97 MB, x86 17.12 → 17.85 MB.
  Without libiconv/uchardet the other changes together make arm64 0.34 MB
  smaller (new dav1d/mbedtls, and mbedtls/libass/libxml2 no longer -O0).
- **FreeType is configured with `-Dharfbuzz=disabled`**: a clean build never
  saw harfbuzz (built after freetype), but any local rebuild of freetype did,
  and produced a different libmpv.so from the same pins.
- `include/download-deps.sh` records what it fetched in `deps/<dep>/.plynic-pin`
  and re-fetches a dependency whose pin changed; `plynic-build.sh` runs it
  before a full build and has `--only dep1,dep2,…` for partial rebuilds.

## Building

Local build on macOS (no Docker): `buildscripts/plynic-build.sh --flavor plynic arm64 armv7l x86_64 x86`,
then `buildscripts/plynic-export.sh` → `buildscripts/out/<abi>/libmpv.so` and
`out/buildinfo.json`; `buildscripts/collect-sources.sh` collects the sources.
See `buildscripts/plynic-build.sh` for the expectations (NDK path, `deps/mpv`
a symlink to a plynic-mpv checkout). Host tools: meson (>= 1.3.0), ninja,
cmake, nasm, pkg-config, python3 (mbedtls's config.py, libplacebo's GL loader
generator), autotools, GNU sed/install (`gsed`, `ginstall` on macOS).
