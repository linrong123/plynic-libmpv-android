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
  others and a warning instead of failing (`tls_mbedtls_ca_partial.patch`);
  a rejected server certificate is logged with the reasons
  (`tls_mbedtls_verify_flags.patch`, format below).
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

## Log lines for embedders

FFmpeg's `tls_mbedtls` messages that an embedder may parse. Through libmpv
they arrive as log messages with prefix `ffmpeg`; the text starts with the
URL protocol's name, `tls: ` (also for the TLS connection under an
`https://` URL or an HLS segment).

**Server certificate rejected** (`tls_verify=1`), two `error` lines, in this
order:

```
tls: tls_mbedtls: certificate verify failed: flags=0x5 (BADCERT_EXPIRED|BADCERT_CN_MISMATCH)
tls: mbedtls_ssl_handshake returned -0x2700
```

- The second line is FFmpeg's own, and it depends on the FFmpeg version.
  FFmpeg 6.0 verifies with `MBEDTLS_SSL_VERIFY_REQUIRED`, so the handshake
  itself fails and it prints `tls: mbedtls_ssl_handshake returned -0x2700`
  (`MBEDTLS_ERR_X509_CERT_VERIFY_FAILED`, the `default` case, above).
  FFmpeg 8.1 verifies with `MBEDTLS_SSL_VERIFY_OPTIONAL` (n8.1.3
  `tls_mbedtls.c:633-635`): mbedtls then lets the handshake succeed, and the
  check after the handshake (`tls_handshake` and `tls_open`, `:486-495` and
  `:687-695`) prints
  `tls: mbedtls_ssl_get_verify_result reported problems with the certificate verification, returned flags: <decimal>`,
  followed, for `BADCERT_NOT_TRUSTED`, by
  `tls: The certificate is not correctly signed by the trusted CA.`.
  (8.1's `handle_handshake_error` has a `Certificate verification failed.`
  case, but under `VERIFY_OPTIONAL` it is never reached. Measured with
  FFmpeg n8.1.2 + mbedtls on macOS: expired, wrong host, untrusted and
  not-yet-valid certificates give flags 1, 4, 8 and 512, and that line never
  appears.) Parse the first
  line; a parser that also accepts FFmpeg's line must accept both versions'
  texts, or it goes blind when the engine moves from one FFmpeg to the other.
  A port of this patch to 8.1 has to print the first line in that
  post-handshake check, not in `handle_handshake_error`.
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

**CA file**: `tls: mbedtls_x509_crt_parse_file for CA cert returned <n>`
(`error`: `n` < 0, or not a single certificate could be parsed) and
`tls: Skipped <n> certificate(s) of the CA file that could not be parsed,
<m> loaded` (`warning`), see `tls_mbedtls_ca_partial.patch`.

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

Local build on macOS (no Docker): `buildscripts/plynic-build.sh --flavor plynic arm64 armv7l`,
then `buildscripts/plynic-export.sh` → `buildscripts/out/<abi>/libmpv.so`.
See `buildscripts/plynic-build.sh` for the expectations (NDK path, `deps/mpv`).
Host tools: meson, ninja, cmake, nasm, pkg-config, python3, autotools, GNU
sed/install (`gsed`, `ginstall` on macOS).
