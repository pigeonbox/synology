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
# GNU stat 先(-c 权限);macOS BSD stat 无 -c 会失败,再落 -f '%Lp'(顺序不可换:
# GNU 的 -f 是"文件系统状态"且成功返回,放前面会吞掉兜底)
assert_eq      ".env 权限 600" "$(stat -c '%a' "$VAR/.env" 2>/dev/null || stat -f '%Lp' "$VAR/.env")" "600"
if [ -d "$DATA" ]; then ok "数据目录已创建"; else fail "数据目录未创建"; fi
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

echo
if [ "$FAIL" -eq 0 ]; then
    echo "✓ 全部通过"
    OK=1
    exit 0
fi
echo "✗ ${FAIL} 项失败"
exit 1
