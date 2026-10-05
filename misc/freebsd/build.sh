#!/usr/bin/env bash
#
# Cross-compiles an Immich server bundle for FreeBSD (amd64) from a Linux host.
#
# The JavaScript parts (server, web, core plugin) are platform independent and
# are built normally. The native addons (sharp + libvips, bcrypt) are
# cross-compiled with clang against a FreeBSD sysroot assembled from the
# official base.txz and binary packages from pkg.freebsd.org.
#
# Host requirements (Debian/Ubuntu package names):
#   clang lld llvm meson ninja-build pkg-config libglib2.0-dev-bin zstd xz-utils
#   curl python3 patchelf unzip, plus node + pnpm (see mise.toml)
#
# Usage: misc/freebsd/build.sh
#   FREEBSD_VERSION  FreeBSD release to target (default 13.3)
#   WORK_DIR         scratch directory (default <repo>/.freebsd-build)
#   OUTPUT           resulting tarball (default <repo>/immich-freebsd<ver>-amd64.tar.gz)

set -euo pipefail

FREEBSD_VERSION="${FREEBSD_VERSION:-13.3}"
FREEBSD_MAJOR="${FREEBSD_VERSION%%.*}"
TARGET="x86_64-unknown-freebsd${FREEBSD_VERSION}"
PKG_REPO="${PKG_REPO:-https://pkg.freebsd.org/FreeBSD:${FREEBSD_MAJOR}:amd64/quarterly}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK_DIR="${WORK_DIR:-$REPO_DIR/.freebsd-build}"
OUTPUT="${OUTPUT:-$REPO_DIR/immich-freebsd${FREEBSD_VERSION}-amd64.tar.gz}"

SYSROOT="$WORK_DIR/sysroot"
STAGE="$WORK_DIR/stage/immich"
NODE_HEADERS_VERSION="$(sed -n 's/^node = "\(.*\)"/\1/p' "$REPO_DIR/mise.toml")"
export CI=1

log() { echo "==> $*"; }
fetch() { curl -sSfL --retry 8 --retry-all-errors -o "$2" "$1"; }

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

#
# 1. FreeBSD sysroot: base system + packages needed to build libvips
#
if [ ! -f "$SYSROOT/.base-done" ]; then
  log "Fetching FreeBSD $FREEBSD_VERSION base system"
  # Releases past end-of-life move to the archive mirror
  BASE_URL="https://download.freebsd.org/releases/amd64/${FREEBSD_VERSION}-RELEASE/base.txz"
  if ! curl -sfI -o /dev/null "$BASE_URL"; then
    BASE_URL="http://ftp-archive.freebsd.org/pub/FreeBSD-Archive/old-releases/amd64/${FREEBSD_VERSION}-RELEASE/base.txz"
  fi
  fetch "$BASE_URL" base.txz
  mkdir -p "$SYSROOT"
  tar -xJf base.txz -C "$SYSROOT" ./usr/include ./usr/lib ./lib ./usr/libdata 2>/dev/null
  rm base.txz
  touch "$SYSROOT/.base-done"
fi

if [ ! -f "$SYSROOT/.pkgs-done" ]; then
  log "Fetching FreeBSD packages from $PKG_REPO"
  fetch "$PKG_REPO/packagesite.pkg" packagesite.pkg
  mkdir -p packagesite pkgs
  tar --zstd -xf packagesite.pkg -C packagesite
  python3 - "$PKG_REPO" "$SYSROOT" vips libultrahdr libimagequant xorgproto <<'EOF'
import json, os, subprocess, sys
repo, sysroot, roots = sys.argv[1], sys.argv[2], sys.argv[3:]
index = {}
for line in open('packagesite/packagesite.yaml'):
    pkg = json.loads(line)
    index[pkg['name']] = pkg
todo, seen = list(roots), set()
while todo:
    name = todo.pop()
    if name in seen:
        continue
    seen.add(name)
    todo.extend((index[name].get('deps') or {}).keys())
for name in sorted(seen):
    path = index[name]['repopath']
    dest = os.path.join('pkgs', os.path.basename(path))
    if not os.path.exists(dest):
        subprocess.run(['curl', '-sSfL', '--retry', '8', '--retry-all-errors', '-o', dest, f'{repo}/{path}'], check=True)
    subprocess.run(['tar', '--zstd', '-xf', dest, '-C', sysroot, '--exclude=+*'], check=True, stderr=subprocess.DEVNULL)
    print(f'  {name} {index[name]["version"]}')
EOF
  touch "$SYSROOT/.pkgs-done"
fi

CC="clang --target=$TARGET --sysroot=$SYSROOT"
CXX="clang++ --target=$TARGET --sysroot=$SYSROOT"

#
# 2. Node headers (only the N-API headers are used, so any recent version works)
#
NODE_HEADERS="$WORK_DIR/node-v$NODE_HEADERS_VERSION/include/node"
if [ ! -d "$NODE_HEADERS" ]; then
  log "Fetching Node $NODE_HEADERS_VERSION headers"
  fetch "https://nodejs.org/dist/v$NODE_HEADERS_VERSION/node-v$NODE_HEADERS_VERSION-headers.tar.gz" node-headers.tar.gz
  tar -xzf node-headers.tar.gz && rm node-headers.tar.gz
fi

#
# 3. JavaScript build (server, web, core plugin)
#
log "Installing workspace dependencies"
cd "$REPO_DIR"
pnpm --filter @immich/sdk --filter @immich/plugin-sdk --filter @immich/plugin-core --filter immich --filter immich-web install --frozen-lockfile

log "Building server and web"
pnpm --filter @immich/sdk build
pnpm --filter @immich/plugin-sdk build
pnpm --filter immich build
pnpm --filter immich-web build

log "Building core plugin"
TOOLS="$WORK_DIR/tools"
if [ ! -x "$TOOLS/bin/extism-js" ]; then
  mkdir -p "$TOOLS/bin"
  EXTISM_JS_VERSION="$(sed -n 's/^"github:extism\/js-pdk" = "\(.*\)"/\1/p' mise.toml)"
  BINARYEN_VERSION="$(sed -n 's/^"github:webassembly\/binaryen" = "\(.*\)"/\1/p' mise.toml)"
  fetch "https://github.com/extism/js-pdk/releases/download/$EXTISM_JS_VERSION/extism-js-x86_64-linux-$EXTISM_JS_VERSION.gz" "$TOOLS/extism-js.gz"
  gunzip -c "$TOOLS/extism-js.gz" > "$TOOLS/bin/extism-js" && chmod +x "$TOOLS/bin/extism-js"
  fetch "https://github.com/WebAssembly/binaryen/releases/download/$BINARYEN_VERSION/binaryen-$BINARYEN_VERSION-x86_64-linux.tar.gz" "$TOOLS/binaryen.tar.gz"
  tar -xzf "$TOOLS/binaryen.tar.gz" -C "$TOOLS"
  cp "$TOOLS/binaryen-$BINARYEN_VERSION/bin/"* "$TOOLS/bin/"
fi
PATH="$TOOLS/bin:$PATH" pnpm --filter @immich/plugin-core build

log "Creating pruned production server"
rm -rf "$WORK_DIR/stage"
mkdir -p "$STAGE/build"
pnpm --filter immich --prod --no-optional deploy "$STAGE/server"
cp -r web/build "$STAGE/build/www"
mkdir -p "$STAGE/build/plugins/immich-plugin-core"
cp -r packages/plugin-core/dist packages/plugin-core/manifest.json "$STAGE/build/plugins/immich-plugin-core/"

SHARP_DIR="$(readlink -f "$STAGE/server/node_modules/sharp")"
BCRYPT_DIR="$(readlink -f "$STAGE/server/node_modules/bcrypt")"
NODE_ADDON_API="$(cd "$SHARP_DIR" && node -p "require('path').dirname(require.resolve('node-addon-api/package.json'))")"
SHARP_VERSION="$(node -p "require('$SHARP_DIR/package.json').version")"
VIPS_VERSION="$(node -p "require('$SHARP_DIR/package.json').config.libvips.replace(/[^0-9.]/g, '')")"
cd "$WORK_DIR"

#
# 4. libvips (FreeBSD's package usually lags behind the version sharp requires)
#
VIPS_PREFIX="$WORK_DIR/vips-$VIPS_VERSION-install/usr/local"
if [ ! -f "$VIPS_PREFIX/lib/libvips-cpp.so.42" ]; then
  log "Cross-compiling libvips $VIPS_VERSION"
  fetch "https://github.com/libvips/libvips/releases/download/v$VIPS_VERSION/vips-$VIPS_VERSION.tar.xz" vips.tar.xz
  rm -rf "vips-$VIPS_VERSION" && tar -xJf vips.tar.xz && rm vips.tar.xz
  cat > freebsd-cross.ini <<EOF
[binaries]
c = ['clang', '--target=$TARGET', '--sysroot=$SYSROOT']
cpp = ['clang++', '--target=$TARGET', '--sysroot=$SYSROOT']
c_ld = 'lld'
cpp_ld = 'lld'
ar = 'llvm-ar'
strip = 'llvm-strip'
pkg-config = 'pkg-config'

[properties]
sys_root = '$SYSROOT'
pkg_config_libdir = ['$SYSROOT/usr/local/share/pkgconfig', '$SYSROOT/usr/local/libdata/pkgconfig', '$SYSROOT/usr/local/lib/pkgconfig', '$SYSROOT/usr/libdata/pkgconfig']

[built-in options]
c_args = ['-I$SYSROOT/usr/local/include']
cpp_args = ['-I$SYSROOT/usr/local/include']
c_link_args = ['-L$SYSROOT/usr/local/lib', '-Wl,-rpath-link,$SYSROOT/usr/local/lib']
cpp_link_args = ['-L$SYSROOT/usr/local/lib', '-Wl,-rpath-link,$SYSROOT/usr/local/lib']

[host_machine]
system = 'freebsd'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF
  (
    cd "vips-$VIPS_VERSION"
    meson setup build --cross-file ../freebsd-cross.ini --prefix=/usr/local --buildtype=release \
      -Dmodules=disabled -Dintrospection=disabled -Ddocs=false -Dcpp-docs=false -Dexamples=false -Ddeprecated=false \
      -Dmagick=disabled -Dpoppler=disabled -Dpdfium=disabled -Dopenslide=disabled -Dmatio=disabled \
      -Dcfitsio=disabled -Dnifti=disabled -Dopenexr=disabled -Dorc=disabled -Dquantizr=disabled
    ninja -C build
    DESTDIR="$WORK_DIR/vips-$VIPS_VERSION-install" meson install -C build --no-rebuild
  )
  for lib in "$VIPS_PREFIX"/lib/libvips.so.42.* "$VIPS_PREFIX"/lib/libvips-cpp.so.42.*; do
    llvm-strip --strip-unneeded "$lib"
    patchelf --force-rpath --set-rpath '$ORIGIN' "$lib"
  done
fi

#
# 5. sharp native addon, linked against the bundled libvips
#
log "Cross-compiling sharp $SHARP_VERSION"
SHARP_OUT="$SHARP_DIR/src/build/Release"
OBJ="$WORK_DIR/obj" && rm -rf "$OBJ" && mkdir -p "$OBJ/sharp" "$OBJ/bcrypt"
for src in common metadata stats operations pipeline utilities sharp; do
  $CXX -c -fPIC -std=c++17 -fexceptions -Os \
    -DG_DISABLE_ASSERT -DG_DISABLE_CAST_CHECKS -DG_DISABLE_CHECKS -DNAPI_VERSION=9 \
    -DNODE_ADDON_API_DISABLE_DEPRECATED -DNODE_API_SWALLOW_UNTHROWABLE_EXCEPTIONS \
    -DSHARP_USE_GLOBAL_LIBVIPS -DBUILDING_NODE_EXTENSION -DNAPI_CPP_EXCEPTIONS \
    -I"$NODE_HEADERS" -I"$NODE_ADDON_API" -I"$VIPS_PREFIX/include" -I"$SYSROOT/usr/local/include" \
    -I"$SYSROOT/usr/local/include/glib-2.0" -I"$SYSROOT/usr/local/lib/glib-2.0/include" \
    "$SHARP_DIR/src/$src.cc" -o "$OBJ/sharp/$src.o"
done
mkdir -p "$SHARP_OUT"
$CXX -fuse-ld=lld -shared -o "$SHARP_OUT/sharp-freebsd-x64-$SHARP_VERSION.node" "$OBJ"/sharp/*.o \
  -L"$VIPS_PREFIX/lib" -L"$SYSROOT/usr/local/lib" -Wl,-rpath-link,"$SYSROOT/usr/local/lib" \
  -lvips-cpp -lvips -lgobject-2.0 -lglib-2.0 \
  -Wl,-s -Wl,-z,nodelete -Wl,--disable-new-dtags -Wl,-rpath,'$ORIGIN'
cp -a "$VIPS_PREFIX"/lib/libvips.so.42* "$VIPS_PREFIX"/lib/libvips-cpp.so.42* "$SHARP_OUT/"

#
# 6. bcrypt native addon
#
log "Cross-compiling bcrypt"
for src in blowfish bcrypt bcrypt_node; do
  $CXX -c -fPIC -O3 -std=c++17 -fexceptions -D_GNU_SOURCE -DNAPI_CPP_EXCEPTIONS -DBUILDING_NODE_EXTENSION \
    -I"$NODE_HEADERS" -I"$NODE_ADDON_API" "$BCRYPT_DIR/src/$src.cc" -o "$OBJ/bcrypt/$src.o"
done
mkdir -p "$BCRYPT_DIR/prebuilds/freebsd-x64"
$CXX -fuse-ld=lld -shared -o "$BCRYPT_DIR/prebuilds/freebsd-x64/bcrypt.node" "$OBJ"/bcrypt/*.o -Wl,-s

#
# 7. Reverse geocoding data (normally baked into the Docker base image)
#
log "Fetching reverse geocoding data"
GEODATA="$STAGE/build/geodata"
mkdir -p "$GEODATA"
for file in cities500.zip admin1CodesASCII.txt admin2Codes.txt countryInfo.txt; do
  fetch "https://download.geonames.org/export/dump/$file" "$GEODATA/$file"
done
unzip -oq "$GEODATA/cities500.zip" -d "$GEODATA" && rm "$GEODATA/cities500.zip"
fetch "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/ne_10m_admin_0_countries.geojson" \
  "$GEODATA/ne_10m_admin_0_countries.geojson"
date --iso-8601=seconds > "$GEODATA/geodata-date.txt"

#
# 8. Service files and tarball
#
mkdir -p "$STAGE/etc/rc.d"
cp "$SCRIPT_DIR/rc.d/immich" "$STAGE/etc/rc.d/immich"
cp "$SCRIPT_DIR/immich.env.sample" "$SCRIPT_DIR/README.md" "$STAGE/"
cp "$REPO_DIR/LICENSE" "$STAGE/LICENSE"

log "Packing $OUTPUT"
tar -czf "$OUTPUT" -C "$WORK_DIR/stage" immich
ls -lh "$OUTPUT"
