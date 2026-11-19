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

# ── shellkit（编译侧统一管道；**设备侧脚本一律不引**，见 C1） ───────────────
# third_party/shellkit 是上游镜像（由 hub 侧 scripts/vendor-shellkit.sh 物化）⇒ **勿手改**。
# ⚠️ 落点是 third_party/ 而不是 vendor/：Go ≥1.14 见到**模块根**下有 vendor/ 就默认切
#    vendor 模式 ⇒ 缺 vendor/modules.txt ⇒ go build 报 "inconsistent vendoring"（实测现红）。
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/third_party/shellkit/lib/bootstrap.sh"
export SHELLKIT_LANG="${SHELLKIT_LANG:-zh_CN}" # 库内消息走中文，与生态输出一致

cd "$REPO_ROOT"

# ── 设备侧 POSIX 子集（装机后生命周期脚本 . 之它）─────────────────────────
# ⚠️ 必须**逐字**进包：改一个字节就与上游镜像脱钩，且设备侧装载的是被改坏的库。
#    缺文件 ⇒ 装机后所有生命周期脚本 fail-closed 退 5 ⇒ 套件装了也起不来。
POSIX_LIB="spk/scripts/lib/shellkit-posix.sh"
if [ ! -f "$POSIX_LIB" ]; then
  log_error "缺设备侧 POSIX 子集: $POSIX_LIB（装机后生命周期脚本会退 5）"
  exit 1
fi

VERSION="${1:?用法: build-spk.sh [版本号] [构建号](例: 0.1.0 0001)}"
BUILD="${2:?缺少构建号(例: 0001)}"
case "$BUILD" in
  [0-9][0-9][0-9][0-9]) ;;
  *)
    log_error "构建号须为 4 位数字(例: 0001)"
    exit 1
    ;;
esac
INFO_VERSION="${VERSION}-${BUILD}"
STAGE="$(mktemp -d)"
# 清理栈 + trap 安装（shellkit 接管 EXIT/INT/TERM/HUP）：处理器取 $? 后原样
# `exit "$__st"` ⇒ **退出码照旧透传** ⇒ 与原手写 trap 等价。
# ⚠️ 原 trap 的「rc==0 且 OK!=1 ⇒ 判失败」成功哨兵**已移除**：本脚本的失败出口穷举为
#   「`${1:?}`/`${2:?}` 退 1、`case` 不匹配退 1、校验和不一致退 1、`set -e` 下命令失败非 0」
#   ⇒ 「跑完却没成功」的出口不存在 ⇒ 哨兵不可达 ⇒ 与原语义等价。
# shellcheck disable=SC2016  # 单引号是**故意的**：清理命令要在 trap 触发时再求值
trap_push 'rm -rf "$STAGE"'
trap_install

# package.tgz:内容解压到 SYNOPKG_PKGDEST(target),升级随包整体替换
PKGDIR="$STAGE/package"
mkdir -p "$PKGDIR"
cp spk/package/compose.yml spk/package/env.example "$PKGDIR/"
(cd "$PKGDIR" && tar -czf "$STAGE/package.tgz" compose.yml env.example)
CHECKSUM="$(md5 -q "$STAGE/package.tgz" 2>/dev/null || md5sum "$STAGE/package.tgz" | cut -d' ' -f1)"

# INFO:注入版本与校验和
sed -e "s/__VERSION__/${INFO_VERSION}/" -e "s/__CHECKSUM__/${CHECKSUM}/" \
  spk/INFO.tmpl >"$STAGE/INFO"

# scripts/conf/WIZARD/图标/LICENSE
cp -R spk/scripts "$STAGE/scripts"
chmod 0755 "$STAGE/scripts/"*
# POSIX 子集是被 . 引入的库，不是可执行脚本 ⇒ 0644（与 fnOS 侧同一约定）
chmod 0644 "$STAGE/scripts/lib/shellkit-posix.sh"
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
  log_error "package.tgz 在 LF 归一化后被改写(校验和 $CHECKSUM → $CHECKSUM_NOW)"
  log_error "⇒ 二进制文件误入文本归一范围,查 find 的排除模式"
  exit 1
fi

# POSIX 子集在 LF 归一后必须仍与源文件逐字一致（归一化若动了它 ⇒ 设备侧装载的是被改坏的库）
_posix_src_sum="$(net_sha256 "$POSIX_LIB" || true)"
_posix_dst_sum="$(net_sha256 "$STAGE/scripts/lib/shellkit-posix.sh" || true)"
if [ -z "$_posix_src_sum" ] || [ "$_posix_src_sum" != "$_posix_dst_sum" ]; then
  log_error "设备侧 POSIX 子集在 LF 归一后被改写（${_posix_src_sum:-无摘要} → ${_posix_dst_sum:-无摘要}）"
  exit 1
fi

OUT="dist/pigeonbox_${INFO_VERSION}.spk"
mkdir -p dist
tar -cf "$OUT" -C "$STAGE" \
  INFO package.tgz scripts conf WIZARD_UIFILES \
  PACKAGE_ICON.PNG PACKAGE_ICON_256.PNG LICENSE

# 产物自检：POSIX 子集必须真的在包里的 scripts/lib/ 下（cp -R 漏层级是最可能的坑）
# 清单落文件再 grep：tar|grep -q 会在 grep 先退出时把 tar 打成 SIGPIPE(141)
# ⇒ pipefail 下误判「缺文件」。
tar -tf "$OUT" > "$STAGE/spk.list"
if ! grep -qx 'scripts/lib/shellkit-posix.sh' "$STAGE/spk.list"; then
  log_error "SPK 里缺 scripts/lib/shellkit-posix.sh"
  exit 1
fi
log_ok "${OUT}"
