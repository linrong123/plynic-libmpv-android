# plynic-libmpv-android

Android `libmpv.so` builds for [plynic](https://github.com/linrong123/plynic),
forked from [media-kit/libmpv-android-video-build](https://github.com/media-kit/libmpv-android-video-build) v1.1.11.

Branches: `plynic/v0.41` builds mpv 0.41 with FFmpeg 8.1 (tags
`v0.41.0-plynic.<n>`); `plynic/v1.1.11` is frozen and is what the 0.36-era
`v1.1.11-plynic.1` … `.7` were built from, the rollback baseline.

The iOS/macOS counterpart is
[plynic-libmpv-darwin](https://github.com/linrong123/plynic-libmpv-darwin):
same plynic-mpv commit, same FFmpeg commit, byte-identical
`buildscripts/patches/ffmpeg/` (its `patches/ffmpeg/`, same keys and sha256
in both manifests), same dependency versions, and the same tag for a pair
of builds.

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
    8.1 branch (see v0.41.0-plynic.rc1 below).
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
  libiconv and uchardet themselves. `DT_NEEDED` is `libm libandroid
  libmediandk libdl libOpenSLES libEGL libc`; a `libc++_shared.so` there would
  keep libmpv.so from loading (the app does not ship one).
- **Every dependency is pinned**: git sources by tag *and* commit
  (`download-deps.sh` refuses a moved tag), tarballs by SHA-256.
- **The complete corresponding source is published with every release**
  (`buildscripts/collect-sources.sh`, see below).
- CI (`.github/workflows/plynic.yaml`): a tag `v<base>-plynic.<n>` builds the
  four ABIs and attaches `plynic-<abi>.jar`, `manifest.json` (digests, sizes,
  build-ids, `DT_NEEDED`, dependency versions and commits, patch digests,
  sources), `debug-symbols-plynic.zip` and `sources/*` to the release; a tag
  `v<base>-plynic.rc<n>` is published as a prerelease.

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
| LLVM libc++ / libc++abi / libunwind (NDK r25c, static) | — | Apache-2.0 WITH LLVM-exception | for libplacebo's C++ parts and uchardet's `operator new`/`delete`; hidden |

The build scripts themselves are MIT (see `LICENSE`). The plynic patches to
mpv are published under mpv's terms in the plynic-mpv repository, the FFmpeg
patches under FFmpeg's.

## Corresponding source

Every release built by the workflow carries, next to the jars, the complete
source its `libmpv.so` was built from (`buildscripts/collect-sources.sh`):
one archive per dependency at the pinned commit (`git archive`, submodules
included) or the upstream release tarball itself (same SHA-256 as upstream's),
the plynic-mpv tree at `v_mpv`, the patches, media-kit-android-helper (the
jar's other `.so` files), this repository at the tagged commit,
`SOURCES.json` (version, licence, upstream location and commit or digest,
SHA-256, patches of each file) and `SHA256SUMS`. `manifest.json` lists the
same files.

Retention: a release that any published plynic version pinned is never
deleted, and its source stays available for at least three years after that
plynic version was last distributed.

## Releases

### v0.41.0-plynic.rc2

rc2 = rc1 + the generic subtitle keep-out band (spec 0017 T-4) + the Darwin
commits (S4.2), the commit both platforms now build (prerelease, not pinned
by the app). FFmpeg, the dependencies and the flavor are unchanged.

- **mpv: plynic-mpv `8235270d93` → `f226dd6356`**:
  - `sub: make sub-keepout a subtitle option of every VO` — the keep-out
    band moved from `vo_mediacodec_osd` into `osd_render()`, as
    `--sub-keepout` (0–50 % of the height, `UPDATE_OSD`), so it also works
    through the render API (texture path). `--vo-mediacodec-osd-sub-keepout`
    is an alias; the app can keep writing it, and can probe
    `option-info/sub-keepout` for the new name.
  - Darwin only (not compiled here): `meson: enable Objective-C on every
    Darwin host`, `ao_audiounit: add --audiounit-skip-session-management`,
    `stream_file: don't ask for the file system type on iOS`.
- **Fetching**: dav1d and libplacebo fall back to their GitHub mirrors
  (`videolan/dav1d`, `haasn/libplacebo`) when code.videolan.org cannot be
  cloned; the pinned commit is checked either way, so the sources are the
  same (the first three CI runs of the rc2 tag failed on "Connection refused" from
  code.videolan.org).
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
- **Known, not new**: the first redraw right after a track switch *while
  paused* races the new track's first decoded subtitle, and nothing redraws
  again until the next change: in 10 runs of that script on rc1 one showed
  an older PGS line there, in 14 on rc2 three showed none (until the next
  keep-out change); the rc1 smoke of wave 1 had the older line as well. To look at in the device matrix (spec 0017 3-6,
  "暂停时切轨").

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
