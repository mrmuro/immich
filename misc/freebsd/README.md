# Immich for FreeBSD 13.3 (amd64)

`build.sh` cross-compiles an Immich server bundle for FreeBSD from a Linux host. It
produces `immich-freebsd13.3-amd64.tar.gz`, which contains:

| Path                    | Contents                                                         |
| ----------------------- | ---------------------------------------------------------------- |
| `server/`               | Compiled server with production `node_modules`                   |
| `build/www/`            | Web UI                                                           |
| `build/plugins/`        | Core workflow plugin (WebAssembly)                               |
| `build/geodata/`        | Reverse geocoding data                                           |
| `etc/rc.d/immich`       | rc(8) service script                                             |
| `immich.env.sample`     | Example environment file                                         |

The JavaScript parts are platform independent. The two native addons are
cross-compiled for FreeBSD with clang:

- **sharp** with a bundled **libvips** (FreeBSD's `graphics/vips` package is older
  than the version sharp requires). libvips is linked against the image libraries
  from FreeBSD packages (libheif, libjxl, libraw, libwebp, ...).
- **bcrypt**

The machine-learning service (Python + ONNX Runtime) is not included. Run the
`immich-machine-learning` container on another host and set
`IMMICH_MACHINE_LEARNING_URL`, or turn machine learning off in the admin settings.

## Building

On Debian/Ubuntu:

```sh
apt-get install clang lld llvm meson ninja-build pkg-config libglib2.0-dev-bin \
  zstd xz-utils curl python3 patchelf unzip
# node and pnpm versions are listed in mise.toml
misc/freebsd/build.sh
```

`FREEBSD_VERSION` (default `13.3`) and `WORK_DIR` can be overridden.

## Installing on FreeBSD 13.3

```sh
# Runtime dependencies
pkg install node24 bash perl5 ffmpeg redis postgresql18-server postgresql18-contrib postgresql18-pgvector \
  postgresql18-vchord \
  cairo cgif expat fftw3 fontconfig gettext-runtime glib highway jpeg-turbo lcms2 libarchive libexif \
  libheif libimagequant libjxl libraw librsvg2-rust libultrahdr openjpeg pango png tiff webp

# Unpack
tar -xzf immich-freebsd13.3-amd64.tar.gz -C /usr/local
install -m 555 /usr/local/immich/etc/rc.d/immich /usr/local/etc/rc.d/immich
cp /usr/local/immich/immich.env.sample /usr/local/etc/immich.env   # edit DB_PASSWORD etc.

# Service user and media directory
pw useradd immich -d /var/db/immich -s /usr/sbin/nologin
mkdir -p /var/db/immich/data && chown -R immich /var/db/immich

# Redis
sysrc redis_enable=YES && service redis start

# PostgreSQL
sysrc postgresql_enable=YES
service postgresql initdb
echo "shared_preload_libraries = 'vchord'" >> /var/db/postgres/data18/postgresql.conf
service postgresql start
su -m postgres -c "psql -c \"CREATE ROLE immich WITH LOGIN SUPERUSER PASSWORD 'change-me';\""
su -m postgres -c "createdb -O immich immich"

# Immich
sysrc immich_enable=YES
service immich start
```

Immich listens on port 2283 and logs to `/var/log/immich.log`.

The database user needs superuser rights on first start so Immich can create
the `vchord`, `vector`, `cube`, `earthdistance`, `pg_trgm` and `unaccent` extensions.
