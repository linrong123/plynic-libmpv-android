# helper.cmake — how libmediakitandroidhelper.so is built, without touching
# media-kit-android-helper's own files: include/helper.init.gradle hands this
# file to its CMake project as CMAKE_PROJECT_INCLUDE, which CMake reads right
# after the project() call, before the library target is defined, so the
# options below apply to it.
#
# Export only the helper's own API: the MediaKitAndroidHelper* functions
# media_kit calls through FFI and the JNI natives, all declared with default
# visibility in native-lib.cpp. Everything else stays inside: -fvisibility
# hides the C++ code the helper instantiates itself, --exclude-libs,ALL what
# it links from a static archive - the NDK's C++ runtime (libc++_static,
# libc++abi, libunwind) and compiler-rt's builtins, which up to rc4 it
# exported whole (about 690 symbols on arm64: std::, __cxa_*,
# __gxx_personality_v0, __emutls_get_address), for every other library in
# the process to bind to.
add_compile_options(-fvisibility=hidden -fvisibility-inlines-hidden)
add_link_options("-Wl,--exclude-libs,ALL")

# How many members lld took from each static archive, next to libmpv.so's
# (prefix/<abi>/), for include/static-system.py.
if(NOT PLYNIC_ARCHIVE_STATS_DIR)
    message(FATAL_ERROR "PLYNIC_ARCHIVE_STATS_DIR is not set (include/helper.init.gradle)")
endif()
add_link_options("-Wl,--print-archive-stats=${PLYNIC_ARCHIVE_STATS_DIR}/${ANDROID_ABI}/libmediakitandroidhelper.archive-stats.tsv")
