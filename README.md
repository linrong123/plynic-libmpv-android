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
  into a second Surface, a JavaVM hook).
- **`--build-id=sha1`** on libmpv.so, so a native crash can be attributed to a
  build and symbolized against the release's `debug-symbols-plynic.zip`.
- Dependency security bumps (FreeType, libass, harfbuzz, fribidi, libxml2).
- CI (`.github/workflows/plynic.yaml`): a tag `v<base>-plynic.<n>` builds the
  four ABIs and attaches `plynic-<abi>.jar`, `manifest.json` (digests, sizes,
  build-ids, dependency versions) and `debug-symbols-plynic.zip` to the release.

Local build on macOS (no Docker): `buildscripts/plynic-build.sh --flavor plynic arm64 armv7l`,
then `buildscripts/plynic-export.sh` → `buildscripts/out/<abi>/libmpv.so`.
See `buildscripts/plynic-build.sh` for the expectations (NDK path, `deps/mpv`).

Licensing is unchanged from upstream: mpv and this build are LGPL-2.1+
(`--disable-gpl` / `-Dgpl=false`); see `LICENSE`. The plynic patches to mpv
are published under the same terms in the plynic-mpv repository.
