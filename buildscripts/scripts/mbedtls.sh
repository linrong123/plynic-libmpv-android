#!/bin/bash -e

. ../../include/depinfo.sh
. ../../include/path.sh

if [ "$1" == "build" ]; then
	true
elif [ "$1" == "clean" ]; then
	make clean
	exit 0
else
	exit 255
fi

$0 clean # separate building not supported, always clean

# The configuration is edited in include/mbedtls/mbedtls_config.h itself, so
# the header FFmpeg compiles tls_mbedtls.c against (installed below) is the one
# the library was built with; `set` is idempotent.
#
# MBEDTLS_PLATFORM_DEV_RANDOM: bionic is not glibc, so mbedtls never takes its
# getrandom() path on Android and reads this file for entropy instead. 3.6.6
# changed the default from /dev/urandom to /dev/random, which blocks on
# kernels older than 5.6 (most Android TV boxes) whenever the kernel thinks
# the pool is low: every HTTPS open would stall. /dev/urandom is what 3.4.0
# read; Android seeds it at boot, long before an app can run.
#
# MBEDTLS_THREADING_C + MBEDTLS_THREADING_PTHREAD: 3.6 turns TLS 1.3 on by
# default, and TLS 1.3 goes through PSA crypto, whose key store and global
# state are only thread-safe with these (global mutexes are statically
# initialised, nothing to call). mpv opens HTTPS connections from several
# threads at once (demuxer, stream cache, external subtitle/audio tracks).
# Up to 3.5 the default was TLS 1.2 only, which uses per-context state.
#
# Left at the 3.6 defaults on purpose: TLS 1.3 itself (3.6.1+ calls
# psa_crypto_init() from the handshake, which FFmpeg 6.0 does not do), and
# NewSessionTicket signalling (3.6.1+ keeps it off, so mbedtls_ssl_read()
# never hands FFmpeg the unknown MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET).
python3 scripts/config.py set MBEDTLS_PLATFORM_DEV_RANDOM '"/dev/urandom"'
python3 scripts/config.py set MBEDTLS_THREADING_C
python3 scripts/config.py set MBEDTLS_THREADING_PTHREAD

# CFLAGS given on the command line replace the Makefiles' own `CFLAGS ?= -O2`,
# so the optimisation level has to be spelled out here (3.4.0 was built -O0).
#
# Only the three static libraries are built and installed. `make install`
# depends on `no_test`, which also builds and links the sample programs, and
# with MBEDTLS_THREADING_PTHREAD set scripts/common.make links those with
# -lpthread, which the NDK does not have (pthreads are in bionic's libc):
# the build then fails on GNU make 4 (CI). macOS's make 3.81 never ran that
# auto-detection, so local builds did not notice. The library Makefile does
# not look at THREADING, so the .a files are the same either way.
make CFLAGS="-O2 -fPIC" CXXFLAGS="-O2 -fPIC" -j$cores lib

# What `make install` put in place, minus the programs (bin/).
mkdir -p "$prefix_dir/include" "$prefix_dir/lib"
rm -rf "$prefix_dir/include/mbedtls" "$prefix_dir/include/psa"
cp -Rp include/mbedtls include/psa "$prefix_dir/include/"
cp -p library/libmbedtls.a library/libmbedx509.a library/libmbedcrypto.a "$prefix_dir/lib/"
