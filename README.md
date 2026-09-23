# plynic-libmpv-android

Android `libmpv.so` builds for [plynic](https://github.com/linrong123/plynic),
forked from [media-kit/libmpv-android-video-build](https://github.com/media-kit/libmpv-android-video-build) v1.1.11.

What differs from upstream:

- **`plynic` flavor** (`buildscripts/flavors/plynic.sh`): upstream `full` without
  `--disable-swscale-alpha` (scaled PGS subtitles came out with opaque black
  boxes) and with the spdif muxer.
- **mpv from [plynic-mpv](https://github.com/linrong123/plynic-mpv)** at a pinned
  commit (`buildscripts/include/depinfo.sh`: `v_mpv`, `v_mpv_repo`): upstream
  78d43740f5 plus a small patch stack (an Android VO that draws OSD/subtitles
  into a second Surface, a JavaVM hook, `ao_audiotrack` fixes).
- **FFmpeg TLS patches** (`buildscripts/patches/ffmpeg/tls_mbedtls_*.patch`):
  with `tls_verify=1`, a host given as an IP address is checked against the
  certificate's iPAddress subjectAltNames (`tls_mbedtls_ip_hostname.patch`);
  a CA file in which some certificates cannot be parsed is used with the
  others and a warning instead of failing (`tls_mbedtls_ca_partial.patch`).
- **`--build-id=sha1`** on libmpv.so, so a native crash can be attributed to a
  build and symbolized against the release's `debug-symbols-plynic.zip`.
- **Subtitle charset detection**: mpv is built with iconv (GNU libiconv) and
  uchardet, so `sub-codepage=auto` turns GBK / Big5 / Shift_JIS / CP1251 …
  external subtitles into UTF-8 instead of Latin-1 mojibake.
- **libmpv.so is linked with `--no-undefined`**: every dynamic import must
  resolve against the NDK stubs at link time, because a libmpv.so with an
  unresolved symbol does not load at all on Android.
- Dependency security bumps; see the table below.
- CI (`.github/workflows/plynic.yaml`): a tag `v<base>-plynic.<n>` builds the
  four ABIs and attaches `plynic-<abi>.jar`, `manifest.json` (digests, sizes,
  build-ids, dependency versions) and `debug-symbols-plynic.zip` to the release.

## Dependencies

Everything below is linked statically into `libmpv.so`. Versions are pinned in
`buildscripts/include/depinfo.sh` (tarballs also by SHA-256) and published in
each release's `manifest.json` under `deps`.

| Library | Version | Licence (as used here) | Notes |
|---|---|---|---|
| mpv (plynic-mpv) | `v_mpv` commit | LGPL-2.1-or-later | `-Dgpl=false` |
| FFmpeg | 6.0 | LGPL-3.0-or-later | `--disable-gpl --enable-version3`; version 3 is what lets it link mbedtls's Apache-2.0 code. `--disable-iconv` on purpose, see the flavor file |
| mbedtls | 3.6.7 (LTS) | Apache-2.0 (dual Apache-2.0 / GPL-2.0-or-later) | release tarball (a git checkout of the tag lacks `framework/`); `MBEDTLS_PLATFORM_DEV_RANDOM="/dev/urandom"`, `MBEDTLS_THREADING_C` + `_PTHREAD`, see `scripts/mbedtls.sh` |
| dav1d | 1.5.4 | BSD-2-Clause | |
| libxml2 | 2.14.6 | MIT | |
| libass | 0.17.5 | ISC | with its NEON (aarch64) and SSE2/AVX2 (x86, x86_64) assembly |
| FreeType | 2.13.3 | FreeType License (dual FTL / GPL-2.0) | |
| FriBidi | 1.0.17 | LGPL-2.1-or-later | |
| HarfBuzz | 11.5.1 | MIT ("Old MIT") | |
| GNU libiconv | 1.19 | LGPL-2.1-or-later | the library only; the GPL-3.0 `iconv` program and its gnulib are never built. Default encoding set (no `--enable-extra-encodings`) |
| uchardet | 0.0.8 | LGPL-2.1-or-later (tri-licensed MPL-1.1 / GPL-2.0-or-later / LGPL-2.1-or-later) | C++ without exceptions/RTTI against the NDK "system" runtime, so libmpv.so gains `DT_NEEDED libstdc++.so` (the platform's operator new/delete, a stable public NDK library) |

The build scripts themselves are MIT (see `LICENSE`). The plynic patches to
mpv are published under mpv's terms in the plynic-mpv repository.

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

Local build on macOS (no Docker): `buildscripts/plynic-build.sh --flavor plynic arm64 armv7l`,
then `buildscripts/plynic-export.sh` → `buildscripts/out/<abi>/libmpv.so`.
See `buildscripts/plynic-build.sh` for the expectations (NDK path, `deps/mpv`).
Host tools: meson, ninja, cmake, nasm, pkg-config, python3, autotools, GNU
sed/install (`gsed`, `ginstall` on macOS).
