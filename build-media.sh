#!/usr/bin/env bash
# Native demuxing for Wine's winedmo; decoding remains in Wine's PE codecs.
set -euo pipefail
[[ $# == 2 ]] || { echo 'Usage: build-media.sh NDK_ROOT OUTPUT' >&2; exit 2; }
ndk="$(realpath "$1")/toolchains/llvm/prebuilt/linux-x86_64"
recipe="$(realpath "$0")"
output="$(realpath -m "$2")"
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
    --enable-demuxers --enable-parsers --enable-bsfs --enable-zlib \
    --enable-shared --disable-static --enable-pic --disable-programs --disable-doc \
    --disable-network --disable-protocols --disable-avdevice --disable-avfilter \
    --disable-swscale --disable-swresample
make -j"${JOBS:-4}"
make install
licenses="$output/prefix/share/licenses/ffmpeg"
mkdir -p "$licenses"
cp "$work/ffmpeg-$version/COPYING.LGPLv2.1" "$work/ffmpeg-$version/LICENSE.md" "$licenses/"
cp "$recipe" "$licenses/"
printf '%s\nSHA-256: %s\n' "$url" "$digest" > "$licenses/SOURCE"
