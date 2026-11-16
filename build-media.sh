#!/usr/bin/env bash
# Native Media Foundation dependencies: FFmpeg demuxing and GStreamer codecs.
set -euo pipefail
[[ $# == 3 ]] || { echo 'Usage: build-media.sh NDK_ROOT BASE_PREFIX OUTPUT' >&2; exit 2; }
ndk="$(realpath "$1")/toolchains/llvm/prebuilt/linux-x86_64"
recipe="$(realpath "$0")"
base="$(realpath "$2")"
output="$(realpath -m "$3")"
[[ ! -e "$output" ]] || { echo 'Output already exists.' >&2; exit 2; }
mkdir -p "$output/work" "$output/prefix"
work="$output/work"
trap 'rm -rf -- "$work"' EXIT
version=8.1.3
url="https://ffmpeg.org/releases/ffmpeg-$version.tar.xz"
digest=7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3
curl -fLsS --retry 5 --retry-all-errors --connect-timeout 20 "$url" -o "$work/source.tar.xz"
printf '%s  %s\n' "$digest" "$work/source.tar.xz" | sha256sum -c -
python3 - "$work" <<'PY'
import sys, tarfile
from pathlib import Path
work = Path(sys.argv[1])
with tarfile.open(work/'source.tar.xz') as archive:
    archive.extractall(work, filter='data')
PY
mkdir "$work/objects"
cd "$work/objects"
"$work/ffmpeg-$version/configure" \
    --prefix="$output/prefix" --libdir="$output/prefix/lib" \
    --target-os=android --arch=aarch64 --cpu=armv8-a --enable-cross-compile \
    --cc="ccache $ndk/bin/aarch64-linux-android29-clang" \
    --ld="$ndk/bin/aarch64-linux-android29-clang" \
    --ar="$ndk/bin/llvm-ar" --ranlib="$ndk/bin/llvm-ranlib" \
    --nm="$ndk/bin/llvm-nm" --strip="$ndk/bin/llvm-strip" \
    --sysroot="$ndk/sysroot" \
    --extra-cflags="-O2 -g0 -ffile-prefix-map=$work=/usr/src/arlinux/ffmpeg" \
    --extra-ldflags='-Wl,-z,max-page-size=16384' \
    --disable-autodetect --disable-everything --enable-avformat --enable-avcodec --enable-avutil \
    --enable-demuxers --enable-parsers --enable-bsfs --enable-decoders --enable-zlib \
    --enable-avfilter --enable-filter=yadif --enable-swscale --enable-swresample \
    --enable-shared --disable-static --enable-pic --disable-programs --disable-doc \
    --disable-network --disable-protocols --disable-avdevice
make -j"${JOBS:-4}"
make install
licenses="$output/prefix/share/licenses/ffmpeg"
mkdir -p "$licenses"
cp "$work/ffmpeg-$version/COPYING.LGPLv2.1" "$work/ffmpeg-$version/LICENSE.md" "$licenses/"
cp "$recipe" "$licenses/"
printf '%s\nSHA-256: %s\n' "$url" "$digest" > "$licenses/SOURCE"

# Reuse the declared Bionic GLib SDK. Meson must not find host Linux libraries.
cat > "$work/media-cross.ini" <<EOF
[binaries]
c = ['ccache', '$ndk/bin/aarch64-linux-android29-clang']
cpp = ['ccache', '$ndk/bin/aarch64-linux-android29-clang++']
[built-in options]
c_args = ['-fPIC', '-D_GNU_SOURCE', '-ffile-prefix-map=$work=/usr/src/arlinux/media']
cpp_args = ['-fPIC', '-D_GNU_SOURCE', '-ffile-prefix-map=$work=/usr/src/arlinux/media']
c_link_args = ['-Wl,-z,max-page-size=16384', '-Wl,-rpath-link,$base/lib', '-Wl,-rpath-link,$output/prefix/lib']
cpp_link_args = ['-Wl,-z,max-page-size=16384', '-Wl,-rpath-link,$base/lib', '-Wl,-rpath-link,$output/prefix/lib']
[properties]
pkg_config_libdir = ['$output/prefix/lib/pkgconfig', '$base/lib/pkgconfig']
EOF
gst_version=1.28.9
build_gst() {
    local name=$1 checksum=$2
    shift 2
    local source_url="https://gstreamer.freedesktop.org/src/$name/$name-$gst_version.tar.xz"
    curl -fLsS --retry 5 --retry-all-errors --connect-timeout 20 "$source_url" -o "$work/$name.tar.xz"
    printf '%s  %s\n' "$checksum" "$work/$name.tar.xz" | sha256sum -c -
    python3 - "$work/$name.tar.xz" "$work" <<'PY'
import sys, tarfile
with tarfile.open(sys.argv[1]) as archive:
    archive.extractall(sys.argv[2], filter='data')
PY
    meson setup "$work/$name-build" "$work/$name-$gst_version" \
        --cross-file "$base/android-cross-export.ini" --cross-file "$work/media-cross.ini" \
        --native-file "$base/native.ini" --wrap-mode=nofallback \
        --prefix="$output/prefix" --libdir=lib --libexecdir=libexec \
        --buildtype=release --default-library=shared -Dauto_features=disabled "$@"
    meson compile -C "$work/$name-build" -j"${JOBS:-4}"
    meson install -C "$work/$name-build"
    local license_dir="$output/prefix/share/licenses/$name"
    mkdir -p "$license_dir"
    cp "$work/$name-$gst_version/COPYING" "$license_dir/"
    printf '%s\nSHA-256: %s\n' "$source_url" "$checksum" > "$license_dir/SOURCE"
}
build_gst gstreamer 6dbf744f583131a34845cc641e803843766a9ba80ce00378a9043fd6d8d5fb38
build_gst gst-plugins-base c1fda668b520e6aef763c0eb962c032c9fe52bce322e8b00c69b4e9e847bddc1 \
    -Dapp=enabled -Daudioconvert=enabled -Daudioresample=enabled -Dplayback=enabled \
    -Dtypefind=enabled -Dvideoconvertscale=enabled
build_gst gst-libav 4b3df21fa70972a80891d2298cf32c14a62c3db4483d545c7ac018230399186b
# gst-libav registers codecs, but deliberately leaves ASF demuxing to this
# upstream plugin. Wine's default byte-stream handler needs both stages.
build_gst gst-plugins-ugly 550a52536962186f5488e06b5c08f31ae0f18400aee32a3385156d31cb4b1189 \
    -Dasfdemux=enabled
