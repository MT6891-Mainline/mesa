#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Cross-build the Mali-G77 capable panfrost libgallium for chopin (aarch64)
# from this Mesa tree on a Debian 13 x86_64 host.
#
# Usage: chopin/build.sh [out-dir]
#
# Environment:
#   WORK       scratch dir (default <workspace>/work/mesa-build)
#   MIRROR     Debian mirror (default tuna)
#   PIP_INDEX  PyPI mirror for meson's python deps
#
# Requires: meson, ninja, aarch64-linux-gnu-gcc, python3, curl, dpkg-deb.
# The arm64 libc/dev packages and the cross g++ are fetched as Debian
# packages and unpacked into a private sysroot, so no root is needed.
#
# The output name matters: Mesa names libgallium (and versions its symbols)
# after the VERSION file, and Debian's libEGL_mesa.so links
# "libgallium-<VERSION>.so" with that exact symbol version, so VERSION is
# kept at the Debian package version of the target rootfs.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(dirname "$here")
ws=$(cd "$repo/../.." && pwd)
out=${1:-"$ws/out-g77"}
work=${WORK:-"$ws/work/mesa-build"}
mirror=${MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/debian}
mesa_version=$(cat "$repo/VERSION")

mkdir -p "$work" "$out"

if command -v dpkg-query >/dev/null 2>&1; then
	host_version=$(dpkg-query -W -f='${Version}' libgl1-mesa-dri 2>/dev/null || true)
	if [ -n "$host_version" ] && [ "$host_version" != "$mesa_version" ]; then
		echo "warning: VERSION is '$mesa_version' but the host's" >&2
		echo "         libgl1-mesa-dri is '$host_version'; the target libEGL_mesa" >&2
		echo "         needs matching symbol versions, update VERSION if the" >&2
		echo "         device's Mesa package has moved." >&2
	fi
fi

# ---------------------------------------------------------------------------
# 1. aarch64 sysroot: libdrm, zlib, expat, plus the X11 pieces Mesa's
#    loader_dri3_helper needs (Debian trixie arm64 debs, unpacked privately)
# ---------------------------------------------------------------------------
sysroot="$work/sysroot"
mkdir -p "$sysroot"
python3 - "$mirror" "$work" "$sysroot" <<'PYDEPS'
import os, re, sys, urllib.request
mirror, work, sysroot = sys.argv[1:4]
pkgs = {
    "libd/libdrm": ["libdrm-dev", "libdrm2"],
    "z/zlib": ["zlib1g-dev", "zlib1g"],
    "e/expat": ["libexpat1-dev", "libexpat1"],
    "libx/libx11": ["libx11-dev", "libx11-6", "libx11-xcb-dev", "libx11-xcb1"],
    "libx/libxcb": ["libxcb1-dev", "libxcb1", "libxcb-randr0-dev", "libxcb-randr0",
                    "libxcb-dri3-dev", "libxcb-dri3-0", "libxcb-present-dev",
                    "libxcb-present0", "libxcb-sync-dev", "libxcb-sync1",
                    "libxcb-xfixes0-dev", "libxcb-xfixes0", "libxcb-shm0-dev",
                    "libxcb-shm0", "libxcb-shape0-dev", "libxcb-shape0",
                    "libxcb-render0-dev", "libxcb-render0"],
    "libx/libxshmfence": ["libxshmfence-dev", "libxshmfence1"],
    "libx/libxau": ["libxau-dev", "libxau6"],
    "libx/libxdmcp": ["libxdmcp-dev", "libxdmcp6"],
    "x/xorgproto": ["x11proto-dev"],
}
for pool, names in pkgs.items():
    url = f"{mirror}/pool/main/{pool}/"
    html = urllib.request.urlopen(url, timeout=90).read().decode("utf-8", "ignore")
    hrefs = re.findall(r'href="([^"]+\.deb)"', html)
    for name in names:
        cands = [h for h in hrefs if h.startswith(name + "_") and
                 (h.endswith("_arm64.deb") or h.endswith("_all.deb")) and
                 "~bpo" not in h and "+deb12" not in h]
        if not cands:
            sys.exit("missing arm64 package: " + name)
        f = sorted(cands)[-1]
        path = os.path.join(work, f)
        if not os.path.exists(path):
            data = urllib.request.urlopen(f"{url}{f}", timeout=120).read()
            open(path, "wb").write(data)
        os.system(f'dpkg-deb -x "{path}" "{sysroot}"')
PYDEPS

# ---------------------------------------------------------------------------
# 2. cross g++ (host package) + shims; Mesa needs a working C++ compiler
# ---------------------------------------------------------------------------
toolchain="$work/toolchain"
if [ ! -x "$toolchain/usr/bin/aarch64-linux-gnu-g++-14" ]; then
	mkdir -p "$toolchain"
	(cd "$work" && apt-get download g++-14-aarch64-linux-gnu \
		libstdc++-14-dev-arm64-cross >/dev/null)
	dpkg-deb -x "$work"/g++-14-aarch64-linux-gnu_*_amd64.deb "$toolchain"
	dpkg-deb -x "$work"/libstdc++-14-dev-arm64-cross_*_all.deb "$toolchain"
	cp -a /usr/libexec/gcc-cross/aarch64-linux-gnu/14/{cc1,collect2,lto1,lto-wrapper,liblto_plugin.so} \
		"$toolchain/usr/libexec/gcc-cross/aarch64-linux-gnu/14/"
fi

mkdir -p "$work/bin"
cat > "$work/bin/aarch64-linux-gnu-g++" <<EOF
#!/bin/sh
T=$toolchain
PATH=$work/bin:/usr/bin:\$PATH
export PATH
exec \$T/usr/bin/aarch64-linux-gnu-g++-14 \\
  -B\$T/usr/libexec/gcc-cross/aarch64-linux-gnu/14/ \\
  -B\$T/usr/lib/gcc-cross/aarch64-linux-gnu/14/ \\
  -B/usr/lib/gcc-cross/aarch64-linux-gnu/14/ \\
  -B/usr/aarch64-linux-gnu/lib/ \\
  -isystem /usr/aarch64-linux-gnu/include \\
  -isystem /usr/lib/gcc-cross/aarch64-linux-gnu/14/include \\
  -isystem \$T/usr/aarch64-linux-gnu/include/c++/14 \\
  -isystem \$T/usr/aarch64-linux-gnu/include/c++/14/aarch64-linux-gnu \\
  -isystem \$T/usr/aarch64-linux-gnu/include/c++/14/backward \\
  "\$@"
EOF
chmod +x "$work/bin/aarch64-linux-gnu-g++"
for t in as ld nm objcopy objdump strip ar ranlib readelf; do
	ln -sf "/usr/bin/aarch64-linux-gnu-$t" "$work/bin/$t"
done

# ---------------------------------------------------------------------------
# 3. Meson needs mako/packaging/yaml; keep them in a private venv
# ---------------------------------------------------------------------------
venv="$work/venv"
if [ ! -x "$venv/bin/python3" ]; then
	python3 -m venv "$venv"
	"$venv/bin/pip" install -q -i "${PIP_INDEX:-https://pypi.tuna.tsinghua.edu.cn/simple}" \
		mako packaging pyyaml
fi

cat > "$work/cross-aarch64.txt" <<EOF
[binaries]
c = 'aarch64-linux-gnu-gcc'
ar = 'aarch64-linux-gnu-ar'
cpp = '$work/bin/aarch64-linux-gnu-g++'
strip = 'aarch64-linux-gnu-strip'
pkg-config = 'pkg-config'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[properties]
pkg_config_libdir = '$sysroot/usr/lib/aarch64-linux-gnu/pkgconfig:$sysroot/usr/share/pkgconfig'
sys_root = '$sysroot'
EOF

# ---------------------------------------------------------------------------
# 4. Configure + build.  EGL is enabled so that meson emits the DRI target;
#    the libgallium it produces is the file Debian's libEGL_mesa loads.
# ---------------------------------------------------------------------------
build="$work/build-git"
rm -rf "$build"
PATH="$venv/bin:$PATH" meson setup "$build" "$repo" \
	--cross-file "$work/cross-aarch64.txt" \
	-Dgallium-drivers=panfrost -Dvulkan-drivers= -Dplatforms=x11 \
	-Dglx=disabled -Dxlib-lease=disabled -Dopengl=true \
	-Dgles2=enabled -Dgles1=disabled \
	-Dllvm=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dzstd=disabled
ninja -C "$build" -j"$(nproc)" \
	"src/gallium/targets/dri/libgallium-$mesa_version.so"

lib="$out/libgallium-$mesa_version.so"
install -m 0644 "$build/src/gallium/targets/dri/libgallium-$mesa_version.so" "$lib"
aarch64-linux-gnu-strip --strip-unneeded "$lib"
echo "built $lib ($(stat -c %s "$lib") bytes)"
echo
echo "install on the device:"
echo "  cp -a /usr/lib/aarch64-linux-gnu/libgallium-$mesa_version.so{,.debian}"
echo "  cp $lib /usr/lib/aarch64-linux-gnu/"
echo "  systemctl restart gdm"
