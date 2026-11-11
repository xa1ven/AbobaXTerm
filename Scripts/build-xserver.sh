#!/bin/bash
# Builds the X server that ships inside AbobaXTerm.app:
#   Vendor/xserver/bin/Xvfb          headless X.org server (the app shows its windows natively)
#   Vendor/xserver/bin/xkbcomp       keymap compiler the server runs at startup
#   Vendor/xserver/share/X11/xkb     keyboard data for xkbcomp
#
# Everything is built from pinned X.org source releases and linked statically,
# so the result depends on nothing but macOS itself. Needs the Xcode command
# line tools and network access; build tools (meson, ninja, pkgconf) are set
# up privately in the work directory, nothing is installed system-wide.
#
#   Scripts/build-xserver.sh            build (resumes where it stopped)
#   Scripts/build-xserver.sh --clean    remove the work directory afterwards
#
# Work directory: build/xserver-work (override with ABX_XSERVER_WORK).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${ABX_XSERVER_WORK:-$ROOT/build/xserver-work}"
OUT="$ROOT/Vendor/xserver"
DIST="$WORK/dist"       # downloaded tarballs
SRC="$WORK/src"         # unpacked sources
PREFIX="$WORK/prefix"   # static libraries and headers the server links against
TOOLS="$WORK/tools"     # meson, ninja, pkgconf
STAGE="$WORK/stage"     # install root of the final programs
JOBS="$(sysctl -n hw.ncpu)"

XORG="https://www.x.org/releases/individual"
# name | version | URL directory | sha256
PACKAGES="
pkgconf|3.0.10|https://distfiles.ariadne.space/pkgconf|9371b2f6372da574d4c6dc96fe9b1463037bcf6afcb6671c1555afde7b17e2de
xorgproto|2026.1|$XORG/proto|f9bfe4a9ed8c8ab9d2a3b0d49797f046052dadd06b7a8b45dbffaffb137e8290
xtrans|1.6.0|$XORG/lib|faafea166bf2451a173d9d593352940ec6404145c5d1da5c213423ce4d359e92
libXau|1.0.12|$XORG/lib|74d0e4dfa3d39ad8939e99bda37f5967aba528211076828464d2777d477fc0fb
xcb-proto|1.17.0|$XORG/proto|2c1bacd2110f4799f74de6ebb714b94cf6f80fb112316b1219480fd22562148c
libxcb|1.17.0|$XORG/lib|599ebf9996710fea71622e6e184f3a8ad5b43d0e5fa8c4e407123c88a59a6d55
libX11|1.8.14|$XORG/lib|bbc78c46217174655c2b32b138ad119f3ac15f50808b4d0b3a2677a4b1afc950
libxkbfile|1.2.0|$XORG/lib|7f71884e5faf56fb0e823f3848599cf9b5a9afce51c90982baeb64f635233ebf
libfontenc|1.1.9|$XORG/lib|9d8392705cb10803d5fe1d27d236cbab3f664e26841ce01916bbbe430cf273e2
libXfont2|2.0.9|$XORG/lib|f042a370666815e7b941e9b7019024755bd1c6c2954afbfa515af378251799e2
pixman|0.46.4|https://www.cairographics.org/releases|a098c33924754ad43f981b740f6d576c70f9ed1006e12221b1845431ebce1239
xorg-server|21.1.26|$XORG/xserver|c8609f9cdafde14de7ec7cb406dac9507add1d536df8d3c3e3d3d9c1cd864066
xkbcomp|1.5.0|$XORG/app|2ac31f26600776db6d9cd79b3fcd272263faebac7eb85fb2f33c7141b8486060
xkeyboard-config|2.47|$XORG/data/xkeyboard-config|e59984416a72d58b46a52bfec1b1361aa7d84354628227ee2783626c7a6db6b6
"

# Hermetic environment: only macOS and our own tools, no Homebrew or XQuartz.
export PATH="$TOOLS/bin:$TOOLS/venv/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PKG_CONFIG="$TOOLS/bin/pkg-config"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
unset PKG_CONFIG_PATH CPATH LIBRARY_PATH
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
export CFLAGS="-O2"
export ACLOCAL_PATH="$PREFIX/share/aclocal"

say() { printf '\n==> %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

field() { echo "$PACKAGES" | awk -F'|' -v n="$1" -v f="$2" '$1 == n { print $f }'; }
version() { field "$1" 2; }
source_dir() { echo "$SRC/$1-$(version "$1")"; }

# Downloads (once), verifies and unpacks a package.
fetch() {
    local name="$1" ver url sum file
    ver="$(version "$name")"; url="$(field "$name" 3)"; sum="$(field "$name" 4)"
    file="$DIST/$name-$ver.tar.xz"
    if [ ! -f "$file" ]; then
        say "Downloading $name $ver"
        curl -fsSL --retry 3 --connect-timeout 20 -o "$file.part" "$url/$name-$ver.tar.xz"
        mv "$file.part" "$file"
    fi
    local actual; actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    if [ "$sum" != "$actual" ]; then
        die "checksum mismatch for $file: expected $sum, got $actual"
    fi
    if [ ! -d "$(source_dir "$name")" ]; then
        tar -xf "$file" -C "$SRC"
    fi
}

# Runs a build step once; a stamp file marks it done.
step() {
    local name="$1"; shift
    local stamp="$WORK/stamps/$name-$(version "$name")"
    [ -f "$stamp" ] && return 0
    fetch "$name"
    say "Building $name $(version "$name")"
    ( cd "$(source_dir "$name")" && "$@" ) > "$WORK/logs/$name.log" 2>&1 \
        || { tail -40 "$WORK/logs/$name.log" >&2; die "$name failed, full log: $WORK/logs/$name.log"; }
    touch "$stamp"
}

# (Chained with &&: `set -e` does not apply inside a function whose result is tested.)
autotools() {
    ./configure --prefix="$PREFIX" --enable-static --disable-shared --disable-dependency-tracking \
        --disable-silent-rules "$@" &&
    make -j"$JOBS" &&
    make install
}

meson_build() {
    rm -rf _build &&
    meson setup _build --prefix="$PREFIX" --libdir=lib --buildtype=release --default-library=static "$@" &&
    ninja -C _build -j"$JOBS" &&
    ninja -C _build install
}

mkdir -p "$DIST" "$SRC" "$PREFIX/lib/pkgconfig" "$PREFIX/share/pkgconfig" "$TOOLS/bin" "$WORK/stamps" "$WORK/logs"

# --- Build tools -------------------------------------------------------------

# Versions that still run on the Python 3.9 of the command line tools; StrEnum is
# what xkeyboard-config needs on a Python older than 3.11.
if [ ! -x "$TOOLS/venv/bin/meson" ] || [ ! -x "$TOOLS/venv/bin/ninja" ] \
    || ! "$TOOLS/venv/bin/python3" -c 'import strenum' 2>/dev/null; then
    say "Setting up meson and ninja"
    /usr/bin/python3 -m venv "$TOOLS/venv"
    "$TOOLS/venv/bin/pip" install --quiet --disable-pip-version-check 'meson==1.11.2' 'ninja==1.13.0' 'StrEnum==0.4.15'
fi

build_pkgconf() {
    ./configure --prefix="$TOOLS" --disable-shared --disable-dependency-tracking &&
    make -j"$JOBS" &&
    make install &&
    # Static linking needs the private dependencies of every library.
    printf '#!/bin/sh\nexec "%s/bin/pkgconf" --static "$@"\n' "$TOOLS" > "$TOOLS/bin/pkg-config" &&
    chmod +x "$TOOLS/bin/pkg-config"
}
step pkgconf build_pkgconf

# zlib comes with macOS but without a pkg-config file.
cat > "$PREFIX/lib/pkgconfig/zlib.pc" <<EOF
Name: zlib
Description: zlib from macOS
Version: 1.2.12
Libs: -lz
EOF

# --- Libraries ---------------------------------------------------------------

step xorgproto meson_build -Dlegacy=false
step xtrans autotools --disable-docs
step libXau autotools
step xcb-proto autotools

# Xlib only needs the core protocol from libxcb.
build_libxcb() {
    local off="" ext
    for ext in composite damage dbe dpms dri2 dri3 glx present randr record render resource screensaver \
               shape shm sync xevie xfixes xfree86-dri xinerama xinput xkb xprint selinux xtest xv xvmc; do
        off="$off --disable-$ext"
    done
    # shellcheck disable=SC2086
    autotools --disable-devel-docs --without-doxygen $off
}
step libxcb build_libxcb

step libX11 autotools --disable-specs --disable-devel-docs --disable-xf86bigfont --disable-loadable-i18n \
    --disable-loadable-xcursor --without-xmlto --without-fop --without-xsltproc --without-launchd
step libxkbfile meson_build
step libfontenc autotools --with-fontrootdir="$PREFIX/share/fonts/X11"
# Core fonts: the built-in "fixed" and "cursor" plus bitmap font files; no FreeType, no font servers.
step libXfont2 autotools --disable-freetype --disable-fc --disable-devel-docs --without-bzip2
step pixman meson_build -Dtests=disabled -Ddemos=disabled -Dgtk=disabled -Dlibpng=disabled -Dopenmp=disabled

# --- Programs ----------------------------------------------------------------

# Paths compiled into the server:
#   xkb_bin_dir "."      xkbcomp is run as ./xkbcomp, so the app starts the server with
#                        its own directory as working directory and the bundle can live anywhere
#   xkb_dir              placeholder, the app passes -xkbdir
#   xkb_output_dir /tmp  scratch files for compiled keymaps
build_xserver() {
    meson_build \
        -Dxvfb=true -Dxorg=false -Dxephyr=false -Dxnest=false -Dxwin=false -Dxquartz=false \
        -Dglamor=false -Dglx=false -Ddri1=false -Ddri2=false -Ddri3=false -Ddrm=false \
        -Dxdmcp=false -Dxdm-auth-1=false -Dsecure-rpc=false -Dipv6=false -Dlisten_tcp=false \
        -Dudev=false -Dudev_kms=false -Dhal=false -Dsystemd_logind=false -Dpciaccess=false \
        -Dvgahw=false -Dint10=false -Ddga=false -Dagp=false -Dlinux_apm=false -Dlinux_acpi=false \
        -Dxselinux=false -Dxv=false -Dxvmc=false -Ddpms=false -Dxf86-input-inputtest=false \
        -Dsha1=CommonCrypto -Ddtrace=false -Ddocs=false -Ddevel-docs=false -Ddocs-pdf=false \
        -Dxkb_bin_dir=. -Dxkb_dir=/usr/share/X11/xkb -Dxkb_output_dir=/tmp \
        -Ddefault_font_path=built-ins \
        -Dvendor_name=AbobaXTerm -Dvendor_name_short=AbobaXTerm -Dbuilder_string="AbobaXTerm built-in X server"
}
step xorg-server build_xserver

step xkbcomp autotools --with-xkb-config-root=/usr/share/X11/xkb
step xkeyboard-config meson_build -Dnls=false -Dcompat-rules=true -Dxorg-rules-symlinks=true

# --- Result ------------------------------------------------------------------

say "Installing into Vendor/xserver"
rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/share/X11"
for program in Xvfb xkbcomp; do
    cp "$PREFIX/bin/$program" "$OUT/bin/$program"
    strip -x "$OUT/bin/$program"
    codesign --force --sign - "$OUT/bin/$program" 2>/dev/null
    # Only libraries that ship with macOS may be linked dynamically.
    if otool -L "$OUT/bin/$program" | tail -n +2 | awk '{print $1}' | grep -v -E '^(/usr/lib/|/System/)'; then
        die "$program links against libraries outside macOS"
    fi
done
cp -RL "$PREFIX/share/X11/xkb" "$OUT/share/X11/xkb"
rm -rf "$OUT/share/X11/xkb/compiled"

{
    echo "X server bundled with AbobaXTerm, built by Scripts/build-xserver.sh from these X.org releases"
    echo "(MIT/X11-style licenses; sources at https://www.x.org/releases/individual/):"
    echo
    echo "$PACKAGES" | awk -F'|' 'NF && $1 != "pkgconf" { printf "  %-18s %s\n", $1, $2 }'
} > "$OUT/VERSIONS"

du -sh "$OUT" "$OUT/bin"/* | sed 's/^/  /'

if [ "${1:-}" = "--clean" ]; then
    rm -rf "$WORK"
fi
