#!/usr/bin/env bash
# 组装 PigeonBox 群晖 SPK(noarch docker-compose 包装,无需官方 toolchain)。
#
# SPK 结构(全部一手来源核实,见 README「参考」节):
#   外层 = 未压缩 tar(勿 gzip,否则套件中心报 Invalid file format)
#     ├── INFO                  key=value 元数据(模板注入版本 + package.tgz 校验和)
#     ├── package.tgz           gzip tar(compose.yml + env.example)
#     ├── scripts/              生命周期脚本(0755)
#     ├── conf/privilege        DSM7 降权声明 + docker 组
#     ├── WIZARD_UIFILES/       安装向导(端口/数据目录/管理员密码)
#     ├── PACKAGE_ICON.PNG      64x64(DSM7 规范)
#     ├── PACKAGE_ICON_256.PNG  256x256
#     └── LICENSE
#
# 用法: ./scripts/build-spk.sh <版本号> <构建号>
#   例: ./scripts/build-spk.sh 0.1.0 0001   → dist/pigeonbox_0.1.0-0001.spk
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?用法: build-spk.sh <版本号> <构建号>(例: 0.1.0 0001)}"
BUILD="${2:?缺少构建号(例: 0001)}"
case "$BUILD" in
    [0-9][0-9][0-9][0-9]) ;;
    *) echo "构建号须为 4 位数字(例: 0001)" >&2; exit 1 ;;
esac
INFO_VERSION="${VERSION}-${BUILD}"
STAGE="$(mktemp -d)"
OK=0
trap 'rc=$?; rm -rf "$STAGE"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

# package.tgz:内容解压到 SYNOPKG_PKGDEST(target),升级随包整体替换
PKGDIR="$STAGE/package"
mkdir -p "$PKGDIR"
cp spk/package/compose.yml spk/package/env.example "$PKGDIR/"
(cd "$PKGDIR" && tar -czf "$STAGE/package.tgz" compose.yml env.example)
CHECKSUM="$(md5 -q "$STAGE/package.tgz" 2>/dev/null || md5sum "$STAGE/package.tgz" | cut -d' ' -f1)"

# INFO:注入版本与校验和
sed -e "s/__VERSION__/${INFO_VERSION}/" -e "s/__CHECKSUM__/${CHECKSUM}/" \
    spk/INFO.tmpl > "$STAGE/INFO"

# scripts/conf/WIZARD/图标/LICENSE
cp -R spk/scripts "$STAGE/scripts"
chmod 0755 "$STAGE/scripts/"*
cp -R spk/conf "$STAGE/conf"
cp -R spk/WIZARD_UIFILES "$STAGE/WIZARD_UIFILES"
cp spk/PACKAGE_ICON.PNG spk/PACKAGE_ICON_256.PNG spk/LICENSE "$STAGE/"

# 文本统一 LF(脚本/INFO 混入 CRLF 是套件执行失败的经典坑)
#
# 2026-10-22 关键修正:**必须排除二进制**(package.tgz / 图标 PNG)。
# perl -pi 按「行」处理文件,行尾 = \n。gzip 的 deflate 数据里**可能**出现
# 0x0D 0x0A 字节对,一旦出现,`s/\r$//` 就把那个 \r 当行尾删掉 ⇒
# **gzip 流被改坏**(CI 报 gzip: invalid compressed data--crc error)。
# 是否命中该字节对取决于压缩产物 ⇒ 表现为**间歇性**(同一 commit push 事件红、
# PR 事件绿);macOS 与 Linux 的压缩字节不同 ⇒ 本地难以复现。
#
# 二进制文件一律不过 perl(只对文本做 LF 归一)。
find "$STAGE" -type f ! -name "*.tgz" ! -name "*.png" ! -name "*.PNG" \
    -exec perl -pi -e 's/\r$//' {} +

# 自校验:package.tgz 在 INFO 里记了 md5,归一化之后必须仍然一致。
# 不一致 = 有二进制被当文本改写了(本 bug 的指纹),构建即红,不让坏包流到 CI。
CHECKSUM_NOW="$(md5 -q "$STAGE/package.tgz" 2>/dev/null || md5sum "$STAGE/package.tgz" | cut -d' ' -f1)"
if [ "$CHECKSUM_NOW" != "$CHECKSUM" ]; then
    echo "✗ package.tgz 在 LF 归一化后被改写(校验和 $CHECKSUM → $CHECKSUM_NOW)" >&2
    echo "  ⇒ 二进制文件误入文本归一范围,查 find 的排除模式" >&2
    exit 1
fi

OUT="dist/pigeonbox_${INFO_VERSION}.spk"
mkdir -p dist
tar -cf "$OUT" -C "$STAGE" \
    INFO package.tgz scripts conf WIZARD_UIFILES \
    PACKAGE_ICON.PNG PACKAGE_ICON_256.PNG LICENSE
echo "✓ ${OUT}"
OK=1
