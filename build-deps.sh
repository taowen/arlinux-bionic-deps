#!/usr/bin/env bash
# Compile Bionic Wine prerequisites with the Linux NDK in a private Linux tree.
set -euo pipefail
[[ $# == 3 ]] || { echo 'Usage: bionic-deps.sh ANDROID_SOURCES LINUX_NDK OUTPUT' >&2; exit 2; }
sources="$(realpath "$1")"
ndk="$(realpath "$2")"
output="$(realpath -m "$3")"
[[ "$(uname -s)" == Linux && "$output" != /mnt/* && "$ndk" != /mnt/* ]] || {
    echo 'Bionic Wine prerequisites require Linux tools and a Linux filesystem build directory.' >&2; exit 2;
}
[[ ! -e "$output" ]] || { echo 'Output already exists.' >&2; exit 2; }
work="$output/work"
mkdir -p "$work/tools/build"
cp "$sources/toolchain.json" "$work/"
for recipe in ndk-env.sh ndk-wayland.sh ndk-deps.sh ndk-xcb.sh android-cross.ini.tpl native.ini.tpl; do
    cp "$sources/tools/build/$recipe" "$work/tools/build/"
done
cp -a "$sources/tools/build/stubs" "$work/tools/build/"
export ARLINUX_DIR="$work" ANDROID_NDK_HOME="$ndk" NDK_PREFIX="$output/prefix" JOBS="${JOBS:-8}"
unset ANDROID_HOME ANDROID_SDK_ROOT ARLINUX_BASH NINJA CC CXX CFLAGS CXXFLAGS LDFLAGS PKG_CONFIG_PATH PKG_CONFIG_LIBDIR
export PATH="$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin:$PATH"
for recipe in ndk-wayland ndk-deps ndk-xcb; do
    bash "$work/tools/build/$recipe.sh"
done

# Only the client library: connect Wine to the existing desktop bus, never
# install or launch another daemon inside the Bionic runtime.
archive="$work/dbus-1.16.2.tar.xz"
curl -L --fail --retry 5 --retry-all-errors --connect-timeout 20 \
    https://dbus.freedesktop.org/releases/dbus/dbus-1.16.2.tar.xz -o "$archive"
printf '%s  %s\n' 0ba2a1a4b16afe7bceb2c07e9ce99a8c2c3508e5dec290dbb643384bd6beb7e2 "$archive" | sha256sum -c -
python3 - "$archive" "$work" <<'DBUS_SOURCE'
import sys, tarfile
with tarfile.open(sys.argv[1]) as source:
    source.extractall(sys.argv[2], filter='data')
DBUS_SOURCE
meson setup "$work/dbus-build" "$work/dbus-1.16.2" \
    --cross-file "$NDK_PREFIX/android-cross-export.ini" --native-file "$NDK_PREFIX/native.ini" \
    --prefix="$NDK_PREFIX" --libdir=lib --buildtype=release --default-library=shared \
    -Dauto_features=disabled -Dmessage_bus=false -Dtools=false \
    -Dtraditional_activation=false -Duser_session=false
meson compile -C "$work/dbus-build" -j"$JOBS"
meson install -C "$work/dbus-build"
mkdir -p "$NDK_PREFIX/share/licenses/dbus-1"
cp "$work/dbus-1.16.2/COPYING" "$NDK_PREFIX/share/licenses/dbus-1/"
printf '%s\n' 'https://dbus.freedesktop.org/releases/dbus/dbus-1.16.2.tar.xz' \
    > "$NDK_PREFIX/share/licenses/dbus-1/SOURCE"
