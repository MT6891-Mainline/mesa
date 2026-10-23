# Mesa 25.0.7 + Mali-G77（chopin / MT6893）

这是 Debian 13 (trixie) 所用 Mesa 25.0.7 的源码树，加上 chopin
（Redmi Note 10 Pro 5G / POCO X3 GT，MT6893/MT6891，Mali-G77）需要的
G77 支持，以及交叉编译脚本。

## 提交历史

| 提交 | 内容 |
| --- | --- |
| `Mesa 25.0.7 (upstream release tarball)` | Debian `mesa_25.0.7.orig.tar.xz` 原样导入 |
| `panfrost: add the Mali-G77` | 唯一的源码改动，见下 |
| `chopin: build tooling` | `chopin/` 构建脚本、说明，以及 Debian 版本号 |

## 改了什么

`src/panfrost/lib/pan_props.c` 的设备表加了一项：

```c
MODEL(0x9080, 0, "G77", "TTRx", HAS_ANISO, 16384, {}),
```

- `0x9080` 是 MT6893 的 G77 product ID；
- `"TTRx"` 是 `src/panfrost/perf/G77.xml` 里的计数器块名；
- TIB 16 KiB、anisotropic 从 r0 起支持，与 G57 相同。

没有这一项时 `panfrost_get_model()` 返回 NULL，EGL 创建 screen 失败，
整个 GL 栈回落到 llvmpipe。

## 为什么 VERSION 是 `25.0.7-2+deb13u1`

Mesa 用 `VERSION` 决定 `libgallium-<version>.so` 的 SONAME，并用
`--default-symver` 把每个导出符号都打上同一个版本节点。Debian 的
`libEGL_mesa.so.0` 直接 `DT_NEEDED libgallium-25.0.7-2+deb13u1.so`，且
引用的是 `driCreateNewScreen3@libgallium-25.0.7-2+deb13u1.so` 这种带版本
符号，所以替换件的 VERSION 必须和**目标 rootfs 里 Mesa 包版本**一致。

`chopin/build.sh` 会拿宿主机的 `libgl1-mesa-dri` 版本做比对，不一致会警告；
如果设备上的 Mesa 升级了，把 `VERSION` 改成新版本号再构建。

## 构建

在 Debian 13 x86_64 宿主机上（不需要 root）：

```sh
./chopin/build.sh /path/to/out
```

脚本会：

- 从 Debian 镜像下载 arm64 的 libdrm/zlib/expat/X11 dev 包，解到私有 sysroot；
- 下载 `g++-14-aarch64-linux-gnu` 和 `libstdc++-14-dev-arm64-cross`，配好
  交叉 g++；
- 在私有 venv 里装 meson 需要的 `mako`/`packaging`/`pyyaml`；
- 用 `-Dgallium-drivers=panfrost -Dplatforms=x11` 配置并编译
  `src/gallium/targets/dri/libgallium-$VERSION.so`；
- strip 后放到输出目录。

产物：`libgallium-25.0.7-2+deb13u1.so`。

`-Dplatforms=x11` 不能省：Debian 的 `libEGL_mesa` 用 `RTLD_NOW` 加载
libgallium，缺 `loader_dri3_*` 符号会整库加载失败，连 Wayland/GBM 都进不去。

## 安装 / 回退（设备上）

```sh
# 先试运行：放到 /root 用 LD_LIBRARY_PATH 验证
mkdir -p /tmp/g77 && cp libgallium-25.0.7-2+deb13u1.so /tmp/g77/
LD_LIBRARY_PATH=/tmp/g77 eglinfo -B     # 应显示 Mali-G77 (Panfrost)

# 确认后替换系统文件
cp -a /usr/lib/aarch64-linux-gnu/libgallium-25.0.7-2+deb13u1.so{,.debian}
cp libgallium-25.0.7-2+deb13u1.so /usr/lib/aarch64-linux-gnu/
systemctl restart gdm

# 回退
cp -a /usr/lib/aarch64-linux-gnu/libgallium-25.0.7-2+deb13u1.so.debian \
      /usr/lib/aarch64-linux-gnu/libgallium-25.0.7-2+deb13u1.so
systemctl restart gdm
```

`apt upgrade` 重装 `libgl1-mesa-dri` 会覆盖回 Debian 版（回到 llvmpipe），
把 `.so` 再拷一次即可。`dpkg -V libgl1-mesa-dri` 可以确认系统文件是否被改过。

## 更新到新 Mesa

1. 用新的 `mesa_<ver>.orig.tar.xz` 做一次 import 提交；
2. cherry-pick / rebase `panfrost: add the Mali-G77` 这个提交；
3. 把 `VERSION` 改成目标 rootfs 的 Mesa 包版本；
4. `./chopin/build.sh`。若上游改了 `pan_props.c` 的表结构，冲突一般只在这一处。

补丁也单独导出了一份在 `chopin/patches/0001-panfrost-add-mali-g77.patch`。
