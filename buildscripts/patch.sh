#!/bin/bash -e
# Resets deps/<dep> and applies patches/<dep>/*, then patches/<dep>-android/*
# (Android only: plynic-libmpv-darwin carries byte-identical copies of
# patches/<dep>/ and has patches/<dep>-darwin/ of its own), each in file
# name order.

PATCHES=(patches/*)
ROOT=$(pwd)

for dep_path in "${PATCHES[@]}"; do
    if [ -d "$dep_path" ]; then
        dep=$(echo $dep_path |cut -d/ -f 2)
        case "$dep" in *-android) continue ;; esac
        patches=($dep_path/*)
        [ -d "patches/$dep-android" ] && patches+=(patches/$dep-android/*)
        cd deps/$dep
        echo Patching $dep
        git reset --hard
        for patch in "${patches[@]}"; do
            echo Applying $patch
            git apply "$ROOT/$patch"
        done
        cd $ROOT
    fi
done

exit 0
