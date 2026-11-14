#!/bin/sh
# SPK 生命周期脚本 mock 冒烟测试(本地与 CI 同一套,无外部依赖):
#   伪造 docker CLI 与 DSM 环境变量,验证 postinst .env 生成、start-stop-status
#   全流程(start/status/stop/log/兜底/重试)与 postupgrade 镜像版本对齐。
# 用法: tests/run-tests.sh
set -u
cd "$(dirname "$0")/.." || exit 1

FAIL=0
ok() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (期望 [$3] 实际 [$2])"; fi
}
assert_contains() {
    case "$2" in
        *"$3"*) ok "$1" ;;
        *) fail "$1 ([$2] 不含 [$3])" ;;
    esac
}
assert_count() {
    want=${4:-1}
    n=$(printf '%s\n' "$2" | grep -c "$3" 2>/dev/null || true)
    if [ "${n:-0}" -eq "$want" ]; then ok "$1"; else fail "$1 (期望恰好 $want 行 [$3],实际 ${n:-0} 行)"; fi
}
assert_ne() {
    if [ "$2" != "$3" ]; then ok "$1"; else fail "$1 (期望不等于 [$3],实际 [$2])"; fi
}
# GNU stat 先(-c 权限);macOS BSD stat 无 -c 会失败,再落 -f '%Lp'(顺序不可换:
# GNU 的 -f 是"文件系统状态"且成功返回,放前面会吞掉兜底)
file_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

TMP="$(mktemp -d)"
OK=0
# shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
trap 'rc=$?; rm -rf "$TMP"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

# ── mock docker:调用记录到 MOCK_LOG,行为由计数文件/开关控制 ──
MOCK_LOG="$TMP/mock-docker.log"
cat > "$TMP/mock-docker" <<'MOCK'
#!/bin/sh
echo "docker $*" >> "${MOCK_LOG:?}"
case "$1" in
    info)
        # 就绪失败计数器(文件),每命中一次减一,归零后成功——测开机重试路径
        f="${MOCK_INFO_FAIL_FILE:-}"
        if [ -n "$f" ] && [ -f "$f" ]; then
            n=$(cat "$f")
            if [ "$n" -gt 0 ]; then echo $((n - 1)) > "$f"; exit 1; fi
        fi
        OK=1
        exit 0
        ;;
    ps)
        [ "${MOCK_PS_EMPTY:-0}" = "1" ] || echo "c0ffee"
        OK=1
        exit 0
        ;;
    *)
        OK=1
        exit 0
        ;;
esac
MOCK
chmod +x "$TMP/mock-docker"

DEST="$TMP/dest"   # SYNOPKG_PKGDEST(包内容)
VAR="$TMP/var"     # SYNOPKG_PKGVAR(@appdata)
mkdir -p "$DEST" "$VAR"
cp spk/package/compose.yml spk/package/env.example "$DEST/"

export MOCK_LOG

echo "── T1 postinst:向导值注入 .env"
DATA="$TMP/nasdata"
LOGMSG="$TMP/usermsg.html"
# postinst 新约束:「尚不存在的目录」必须 /volume* —— 测试机无卷可写,预创建
# $DATA 走「存量目录放行」分支(与真机升级路径同分支,不误伤)。新建目录的
# mkdir 分支在测试机不可测(创建 /volume* 需 root),由真机安装覆盖。
mkdir -p "$DATA"
SYNOPKG_PKGDEST="$DEST" SYNOPKG_PKGVAR="$VAR" SYNOPKG_TEMP_LOGFILE="$LOGMSG" \
    wizard_host_port=8080 wizard_data_dir="$DATA" wizard_admin_password=s3cret \
    sh spk/scripts/postinst
rc=$?
assert_eq "postinst 退出码" "$rc" "0"
assert_contains ".env 注入端口"    "$(cat "$VAR/.env")" "PB_API_PORT=8080"
assert_contains ".env 注入数据目录" "$(cat "$VAR/.env")" "PB_DATA_DIR=$DATA"
assert_contains ".env 注入密码"    "$(cat "$VAR/.env")" "PB_ADMIN_PASSWORD=s3cret"
assert_count   ".env 模板行保留且唯一(IMAGE_TAG)" "$(cat "$VAR/.env")" "^PB_IMAGE_TAG="
assert_count   ".env 注册开关保留且唯一"           "$(cat "$VAR/.env")" "^PB_USER_ALLOW_REGISTRATION="
assert_eq      ".env 权限 600" "$(file_mode "$VAR/.env")" "600"
if [ -d "$DATA" ]; then ok "存量数据目录放行后仍在"; else fail "存量数据目录被误删/误拒"; fi
assert_contains "用户消息含端口" "$(cat "$LOGMSG")" "8080"

echo "── T2 postinst:重复执行不覆盖既有 .env"
SYNOPKG_PKGDEST="$DEST" SYNOPKG_PKGVAR="$VAR" SYNOPKG_TEMP_LOGFILE="$LOGMSG" \
    wizard_host_port=9999 wizard_data_dir="$DATA" wizard_admin_password=x \
    sh spk/scripts/postinst
assert_contains "既有 .env 未被覆盖" "$(cat "$VAR/.env")" "PB_API_PORT=8080"

echo "── T3 postupgrade:镜像 tag 对齐包内真相源(env.example),其余配置保留"
# 1.14.x 起包版本=发布列车号、镜像版本=0.15.x 两者脱钩且 ghcr tag 无 v 前缀
# (62ca9e9 修正:真相源=包根 env.example,旧「v+包主版本」推导指向不存在的 tag
# 会令升级后拉镜像必败)——期望值动态取自包内模板,随列车不改断言。
WANT_TAG=$(sed -n 's/^PB_IMAGE_TAG=//p' "$DEST/env.example" | head -1)
printf 'PB_API_PORT=8080\nPB_DATA_DIR=%s\nPB_IMAGE_TAG=v0.1.0\n' "$DATA" > "$VAR/.env"
SYNOPKG_PKGDEST="$DEST" SYNOPKG_PKGVAR="$VAR" SYNOPKG_PKGVER="0.2.0-0001" SYNOPKG_TEMP_LOGFILE="$LOGMSG" \
    sh spk/scripts/postupgrade
rc=$?
assert_eq "postupgrade 退出码" "$rc" "0"
assert_contains "镜像 tag 刷新到包内真相源($WANT_TAG)" "$(cat "$VAR/.env")" "PB_IMAGE_TAG=$WANT_TAG"
assert_contains "端口保留"               "$(cat "$VAR/.env")" "PB_API_PORT=8080"
assert_count   "IMAGE_TAG 恰好一行"      "$(cat "$VAR/.env")" "^PB_IMAGE_TAG="

# T13: postupgrade 后 .env 权限必须仍为 600(mv 重写曾把 600 放宽成 644,synology#148)
# 前置:复用 T3 的升级脚本执行现场——必须紧跟 postupgrade 之后,
# 后面 T3.5/T10 都会用 printf 重写 .env(默认 umask ⇒ 644),挪走就测不到升级脚本了。
mode=$(file_mode "$VAR/.env")
assert_eq "postupgrade 后 .env 权限" "$mode" "600"

echo "── T3.5 postupgrade:1.14.3 形态(FCB_ 前缀)存量 .env 迁移到 PB_"
printf 'FCB_API_PORT=8080\nFCB_DATA_DIR=%s\nFCB_ADMIN_PASSWORD=s3cret\nFCB_IMAGE_TAG=v1.14.3\nPB_USER_ALLOW_REGISTRATION=false\n' "$DATA" > "$VAR/.env"
SYNOPKG_PKGDEST="$DEST" SYNOPKG_PKGVAR="$VAR" SYNOPKG_PKGVER="1.14.4-0001" SYNOPKG_TEMP_LOGFILE="$LOGMSG" \
    sh spk/scripts/postupgrade
rc=$?
assert_eq "迁移升级退出码" "$rc" "0"
assert_contains "迁移:端口"     "$(cat "$VAR/.env")" "PB_API_PORT=8080"
assert_contains "迁移:数据目录" "$(cat "$VAR/.env")" "PB_DATA_DIR=$DATA"
assert_contains "迁移:密码"     "$(cat "$VAR/.env")" "PB_ADMIN_PASSWORD=s3cret"
assert_contains "迁移:镜像对齐" "$(cat "$VAR/.env")" "PB_IMAGE_TAG=$WANT_TAG"
assert_count   "迁移:无 FCB_ 残留" "$(cat "$VAR/.env")" "^FCB_" 0

echo "── T14 postinst:新数据目录必须 /volume*(存量目录不误伤)"
# 以全新 PKGVAR 重放 postinst(wizard_* 注入),覆盖向导/CLI 装机入口。
# 约束只作用于「尚不存在的目录」——升级路径上的存量目录不回溯拒绝。
# 拒绝用例落在 $TMP 下(非 /volume* 即可):RED 阶段脚本会真 mkdir,写 /etc 会污染机器。
run_postinst_with() {
    _pv="$TMP/var-t14"
    rm -rf "$_pv"
    mkdir -p "$_pv"
    SYNOPKG_PKGDEST="$DEST" SYNOPKG_PKGVAR="$_pv" SYNOPKG_TEMP_LOGFILE="$LOGMSG" \
        wizard_host_port=8080 wizard_data_dir="$1" wizard_admin_password=s3cret \
        sh spk/scripts/postinst
}
run_postinst_with "$TMP/pb-reject-test" 2>/dev/null
assert_ne "postinst 拒绝非卷新数据目录" "$?" "0"
run_postinst_with /volume1/pb-accept-test 2>/dev/null
assert_eq "postinst 接受 /volume* 新数据目录" "$?" "0"

echo "── T4 start:按 .env 组装 compose 命令"
: > "$MOCK_LOG"
SYNOPKG_DOCKER_BIN="$TMP/mock-docker" SYNOPKG_PKGDEST="$DEST" SYNOPKG_PKGVAR="$VAR" \
    sh spk/scripts/start-stop-status start
rc=$?
assert_eq "start 退出码" "$rc" "0"
assert_contains "compose up -d 已调用"      "$(cat "$MOCK_LOG")" "up -d"
assert_contains "项目名固定 pigeonbox"    "$(cat "$MOCK_LOG")" "-p pigeonbox"
assert_contains "env-file 指向 PKGVAR/.env" "$(cat "$MOCK_LOG")" "--env-file $VAR/.env"
assert_contains "-f 指向包内 compose.yml"    "$(cat "$MOCK_LOG")" "-f $DEST/compose.yml"
if [ -d "$DATA" ]; then ok "start 兜底数据目录已建"; else fail "start 兜底数据目录未建"; fi

echo "── T5 status:LSF 语义"
: > "$MOCK_LOG"
SYNOPKG_DOCKER_BIN="$TMP/mock-docker" SYNOPKG_PKGDEST="$DEST" SYNOPKG_PKGVAR="$VAR" \
    sh spk/scripts/start-stop-status status
assert_eq "容器在跑 → 0" "$?" "0"
MOCK_PS_EMPTY=1 SYNOPKG_DOCKER_BIN="$TMP/mock-docker" SYNOPKG_PKGDEST="$DEST" SYNOPKG_PKGVAR="$VAR" \
    sh spk/scripts/start-stop-status status
assert_eq "容器不在 → 3" "$?" "3"

echo "── T6 stop:down 幂等容忍失败"
: > "$MOCK_LOG"
SYNOPKG_DOCKER_BIN="$TMP/mock-docker" SYNOPKG_PKGDEST="$DEST" SYNOPKG_PKGVAR="$VAR" \
    sh spk/scripts/start-stop-status stop
assert_eq "stop 退出码" "$?" "0"
assert_contains "down --remove-orphans 已调用" "$(cat "$MOCK_LOG")" "down --remove-orphans"

echo "── T7 log:输出日志路径"
out=$(SYNOPKG_DOCKER_BIN="$TMP/mock-docker" SYNOPKG_PKGDEST="$DEST" SYNOPKG_PKGVAR="$VAR" \
    sh spk/scripts/start-stop-status log)
assert_eq "log 输出日志文件路径" "$out" "$VAR/pigeonbox.log"

echo "── T8 start:.env 缺失时从包内 env.example 兜底"
rm -f "$VAR/.env"
SYNOPKG_DOCKER_BIN="$TMP/mock-docker" SYNOPKG_PKGDEST="$DEST" SYNOPKG_PKGVAR="$VAR" \
    sh spk/scripts/start-stop-status start
assert_eq "start 退出码" "$?" "0"
if [ -f "$VAR/.env" ]; then ok ".env 已兜底生成"; else fail ".env 未兜底生成"; fi

echo "── T9 start:docker daemon 未就绪时重试后成功(约 10s)"
: > "$MOCK_LOG"
echo 2 > "$TMP/info-fails"   # 前 2 次 info 失败(2×sleep 5s)
MOCK_INFO_FAIL_FILE="$TMP/info-fails" SYNOPKG_DOCKER_BIN="$TMP/mock-docker" \
    SYNOPKG_PKGDEST="$DEST" SYNOPKG_PKGVAR="$VAR" \
    sh spk/scripts/start-stop-status start
assert_eq "重试后 start 成功" "$?" "0"

# 快照文件枚举/计数(用 glob 而非 ls:shellcheck SC2012 会判红,且 glob 在无匹配时
# 保持字面量,配 [ -f ] 判断即可)
bak_count() {
    _n=0
    for _f in "$1"/fileCodeBox.db.bak-*; do
        [ -f "$_f" ] && _n=$((_n + 1))
    done
    echo "$_n"
}
bak_newest() {
    for _f in "$1"/fileCodeBox.db.bak-*; do
        [ -f "$_f" ] && printf '%s\n' "$_f"
    done | sort -r | head -1
}

echo "── T10 preupgrade:升级前快照业务库(轮转保留 3 份)"
# 迁移前快照 = 唯一回滚点(4.0.0 的删列/布局上提不可逆)。DSM 先 stop 再跑本
# 脚本 ⇒ 库静止且仍是旧 schema。全新安装时本脚本也会跑 ⇒ 没有库必须放行。
# T8 把 .env 重置成模板(PB_DATA_DIR 为空)⇒ 这里先恢复安装向导形态的 .env,
# 顺带覆盖「按 .env 的 PB_DATA_DIR 定位数据目录」这条口径。
printf 'PB_API_PORT=8080\nPB_DATA_DIR=%s\n' "$DATA" > "$VAR/.env"
rm -f "$DATA/fileCodeBox.db" "$DATA"/fileCodeBox.db.bak-* 2>/dev/null
SYNOPKG_PKGDEST="$DEST" SYNOPKG_PKGVAR="$VAR" sh spk/scripts/preupgrade
assert_eq "无库(全新安装)放行" "$?" "0"
if [ "$(bak_count "$DATA")" -gt 0 ]; then
    fail "无库时不该产生快照"
else
    ok "无库时未产生快照"
fi

printf 'OLD-SCHEMA-DB' > "$DATA/fileCodeBox.db"
SYNOPKG_PKGDEST="$DEST" SYNOPKG_PKGVAR="$VAR" sh spk/scripts/preupgrade
assert_eq "有库时退出码 0" "$?" "0"
assert_eq "生成 1 份快照" "$(bak_count "$DATA")" "1"
assert_eq "快照与源库逐字一致" "$(cat "$(bak_newest "$DATA")")" "OLD-SCHEMA-DB"
# 轮转:预置 3 份更旧的快照(名字里的时间戳更早),新快照进来后总数必须仍是 3
# ⇒ 最旧的一份被删。轮转按**名字**排序,故这里不依赖 mtime,无需 touch。
rm -f "$DATA"/fileCodeBox.db.bak-* 2>/dev/null
for _s in 20000101-000001 20000101-000002 20000101-000003; do
    printf 'x' > "$DATA/fileCodeBox.db.bak-$_s"
done
SYNOPKG_PKGDEST="$DEST" SYNOPKG_PKGVAR="$VAR" sh spk/scripts/preupgrade
assert_eq "第 4 份进来后仍只保留 3 份" "$(bak_count "$DATA")" "3"
# 反向:被删的必须是最旧那份(名字最小),否则等于删掉了最有用的回滚点
if [ -f "$DATA/fileCodeBox.db.bak-20000101-000001" ]; then
    fail "轮转删错了对象(最旧的一份仍在)"
else
    ok "轮转删的是最旧的一份"
fi

echo "── T11 preupgrade:备份失败中止升级(root 下无法注入,跳过)"
# 赌不起的时候不赌:库拷不动(卷满/权限变了)时继续升级 = 在没有回滚点的状态下
# 跑不可逆迁移。用权限位注入 cp 失败;root 可无视权限位 ⇒ 跳过以免假红。
if [ "$(id -u)" -ne 0 ]; then
    _before=$(bak_count "$DATA")
    chmod 000 "$DATA/fileCodeBox.db"
    if ( SYNOPKG_PKGDEST="$DEST" SYNOPKG_PKGVAR="$VAR" sh spk/scripts/preupgrade ) >/dev/null 2>&1; then
        fail "备份失败未被拦下(应中止升级)"
    else
        ok "备份失败时中止升级(旧版本与数据不动)"
    fi
    chmod 600 "$DATA/fileCodeBox.db"
    assert_eq "中止路径不留下半份快照" "$(bak_count "$DATA")" "$_before"
else
    ok "root 环境无法用权限位注入 cp 失败,跳过中止分支"
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "✓ 全部通过"
    OK=1
    exit 0
fi
echo "✗ ${FAIL} 项失败"
exit 1
