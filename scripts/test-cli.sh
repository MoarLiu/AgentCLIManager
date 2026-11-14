#!/bin/sh
# acm 命令行的端到端断言：构建后对着 mktemp 出来的假家目录跑，检查退出码和关键输出。
#
# 安全约定：
#   - 绝不带 --execute 对真实家目录操作。所有 --execute 都带 --home <假家目录>，
#     且调用前用 assert_fake_home 确认它在 mktemp 的根之下。
#   - 往返测试会把自建的假文件短暂放进当前用户的真实废纸篓再取回，
#     结束时确认没有留下自己的东西；放回失败会把遗留路径打印出来。
#
# 环境变量：
#   ACM_UNDO_VALIDATION=1（默认）启用手写恶意回执的断言。这条依赖 Uninstaller.restore
#   的「trashed 必须在 env.trashDirs 内、original 必须过路径护栏」校验；如果副本里
#   那段校验还没合进来，这条会失败——那属于「预期在合并后通过」，不是本脚本的 bug。
#   要在校验未合入的副本上跑通其余断言，用 ACM_UNDO_VALIDATION=0 ./scripts/test-cli.sh。

set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

ACM_UNDO_VALIDATION=${ACM_UNDO_VALIDATION:-1}

PASS=0
FAIL=0
FAILED_NAMES=""

pass() {
    PASS=$((PASS + 1))
    printf 'ok   %s\n' "$1"
}
fail() {
    FAIL=$((FAIL + 1))
    FAILED_NAMES="$FAILED_NAMES
  $1"
    printf 'FAIL %s\n' "$1"
    shift
    for line in "$@"; do printf '     %s\n' "$line"; done
}

# 跑 acm，捕获退出码与输出。用法：run <名字> <期望退出码> [acm 参数...]
CODE=0
OUT=""
run() {
    name=$1
    expected=$2
    shift 2
    # 每次执行前集中核对，避免新加用例漏掉假家目录护栏。
    moving=0
    fake_home=""
    previous=""
    for argument in "$@"; do
        [ "$argument" = "--execute" ] && moving=1
        [ "$previous" = "--home" ] && fake_home=$argument
        previous=$argument
    done
    [ "$1" = "plan" ] || moving=0
    [ "$1" = "undo" ] && [ -n "$fake_home" ] && moving=1
    if [ "$moving" -eq 1 ]; then assert_fake_home "$fake_home"; fi
    OUT=$("$ACM" "$@" 2>&1)
    CODE=$?
    if [ "$CODE" -eq "$expected" ]; then
        pass "$name"
    else
        fail "$name" "期望退出码 ${expected}，实际 $CODE" "$OUT"
    fi
}

expect_contains() {
    case $OUT in
        *"$2"*) pass "$1" ;;
        *) fail "$1" "输出里应包含「$2」" "$OUT" ;;
    esac
}
expect_not_contains() {
    case $OUT in
        *"$2"*) fail "$1" "输出里不应包含「$2」" "$OUT" ;;
        *) pass "$1" ;;
    esac
}

# --execute 之前的强制检查：目录必须在 mktemp 根之下。
assert_fake_home() {
    case $1 in
        "$TMPROOT"/*) ;;
        *) printf '拒绝执行：%s 不在 %s 之下\n' "$1" "$TMPROOT" >&2; exit 99 ;;
    esac
}

# ---------- 构建 ----------
printf '构建 acm…\n'
if ! swift build --product acm > "$ROOT/.build/test-cli-build.log" 2>&1; then
    printf '构建失败：\n' >&2
    tail -30 "$ROOT/.build/test-cli-build.log" >&2
    exit 1
fi
BIN=$(swift build --product acm --show-bin-path 2>/dev/null)
ACM="$BIN/acm"
[ -x "$ACM" ] || { printf '找不到 %s\n' "$ACM" >&2; exit 1; }

TMPROOT=$(mktemp -d /tmp/acm-cli-test.XXXXXX)
TRASH_LEFTOVER=""

cleanup() {
    # 只删自己 mktemp 出来的根，绝不碰别的。
    case $TMPROOT in
        /tmp/acm-cli-test.*)
            chflags -R nouchg "$TMPROOT"
            chmod -R u+w "$TMPROOT"
            rm -rf "$TMPROOT"
            ;;
    esac
    if [ -n "$TRASH_LEFTOVER" ]; then
        printf '\n注意：以下测试文件还留在废纸篓里，请手工放回或删除：\n%s\n' "$TRASH_LEFTOVER" >&2
    fi
}
trap cleanup EXIT INT TERM

HOME1="$TMPROOT/home"
mkdir -p "$HOME1/.local/bin"
printf '#!/bin/sh\nexit 0\n' > "$HOME1/.local/bin/claude"
chmod +x "$HOME1/.local/bin/claude"
printf '#!/bin/sh\nexit 0\n' > "$HOME1/.local/bin/codex"
chmod +x "$HOME1/.local/bin/codex"

# ---------- R05：--home 缺值 / 无效 ----------

# 真实家目录的只读扫描输出，用来比对「缺值时不能退回真实家目录」。
REAL_SCAN=$("$ACM" scan --no-processes 2>/dev/null)

run "scan --home --json 退出码 2" 2 scan --home --json
expect_not_contains "scan --home --json 不含真实扫描结果" "命令目录"
if [ -n "$REAL_SCAN" ]; then
    expect_not_contains "scan --home --json 不等于真实家目录扫描" "$REAL_SCAN"
fi
expect_contains "scan --home --json 报错提到 --home" "--home"

run "scan --home 结尾缺值 退出码 2" 2 scan --home
run "scan --home 不存在的目录 退出码 2" 2 scan --home "$TMPROOT/does-not-exist"
expect_contains "不存在的目录有说明" "已存在的目录"

run "scan --home 指向普通文件 退出码 2" 2 scan --home "$HOME1/.local/bin/claude"

run "scan --bogus 退出码 2" 2 scan --bogus
run "未知子命令 frobnicate 退出码 2" 2 frobnicate
run "重复选项 退出码 2" 2 scan --json --json
run "多余位置参数 退出码 2" 2 scan extra
run "plan 缺目标 退出码 2" 2 plan

run "undo --all 退出码 2" 2 undo --receipts "$TMPROOT/r.json" --all
run "undo --execute 退出码 2" 2 undo --receipts "$TMPROOT/r.json" --execute

# ---------- 帮助 ----------
run "--help 退出码 0" 0 --help
run "scan -h 退出码 0" 0 scan -h
expect_contains "帮助里有退出码说明" "退出码"

# ---------- R13：模糊匹配 ----------
run "plan Code 命中多个 退出码 2" 2 plan Code --home "$HOME1" --no-processes
expect_contains "歧义列出 claude-code" "cli:claude-code"
expect_contains "歧义列出 codex" "cli:codex"
run "plan Code --execute 同样拒绝歧义" 2 plan Code --home "$HOME1" --execute --no-processes
run "plan claude-code 精确 id 退出码 0" 0 plan claude-code --home "$HOME1" --no-processes
run "plan Claude Code 精确名字 退出码 0" 0 plan "Claude Code" --home "$HOME1" --no-processes
run "plan claude code 名字大小写不敏感" 0 plan "claude code" --home "$HOME1" --no-processes
run "plan nosuchtool 找不到 退出码 1" 1 plan nosuchtool --home "$HOME1" --no-processes

# ---------- 发布回归：全选排除独立凭据，父目录覆盖凭据时仍提示 ----------
CREDENTIAL_HOME="$TMPROOT/credential-home"
mkdir -p "$CREDENTIAL_HOME/.grok"
printf '{}\n' > "$CREDENTIAL_HOME/.grok/auth.json"
run "凭据：父目录折叠后仍生成计划" 0 plan grok-cli --all --home "$CREDENTIAL_HOME" --no-processes
expect_contains "凭据：父目录覆盖时列出凭据路径" "auth.json"
expect_contains "凭据：父目录覆盖时提示废纸篓风险" "Time Machine"

mkdir -p "$CREDENTIAL_HOME/Library/Application Support/AgentCLIManager"
printf '{"schemaVersion":1,"products":[{"id":"credential-only","name":"Credential Only","kind":"cli","binaries":["credential-tool"],"paths":[{"path":"~/.credential-only/auth.json","kind":"credentials"}]}]}\n' \
    > "$CREDENTIAL_HOME/Library/Application Support/AgentCLIManager/catalog.json"
mkdir -p "$CREDENTIAL_HOME/.credential-only"
printf '{}\n' > "$CREDENTIAL_HOME/.credential-only/auth.json"
run "凭据：全选排除独立凭据" 0 plan credential-only --all --home "$CREDENTIAL_HOME" --no-processes
expect_contains "凭据：独立凭据不会进入移动计划" "将移走 0 项"

# ---------- R09：回执 ----------
assert_fake_home "$HOME1"
run "receipts 父目录不存在 退出码 2" 2 \
    plan claude-code --home "$HOME1" --execute --receipts "$TMPROOT/no-such-dir/r.json" --no-processes
if [ -x "$HOME1/.local/bin/claude" ] && [ -x "$HOME1/.local/bin/codex" ]; then
    pass "回执写不进去时文件原封不动"
else
    fail "回执写不进去时文件原封不动" "$(ls -la "$HOME1/.local/bin")"
fi

mkdir -p "$TMPROOT/receipt-target"
run "receipts 指向目录 退出码 2" 2 \
    plan claude-code --home "$HOME1" --execute --receipts "$TMPROOT/receipt-target" --no-processes
[ -x "$HOME1/.local/bin/claude" ] && pass "回执是目录时也不动文件" || fail "回执是目录时也不动文件"

run "receipts 不带 --execute 退出码 2" 2 \
    plan claude-code --home "$HOME1" --receipts "$TMPROOT/r.json" --no-processes

# 实际路径排他预留也必须拒绝只读父目录，且一项都不移。
READONLY_DIR="$TMPROOT/readonly-dir"
mkdir -p "$READONLY_DIR"
chmod 555 "$READONLY_DIR"
assert_fake_home "$HOME1"
run "receipts 父目录只读 退出码 2" 2 \
    plan claude-code --home "$HOME1" --execute --receipts "$READONLY_DIR/r.json" --no-processes
[ -x "$HOME1/.local/bin/claude" ] && pass "父目录只读时一项都没移" || fail "父目录只读时一项都没移"
chmod 755 "$READONLY_DIR"

# --execute 不带 --receipts：允许，但执行前要向 stderr 提示。这里目标不存在，
# 所以最终退出码是 1，但能验证提示确实打出来了，且没有回执也能走到目标匹配。
EMPTY_HOME="$TMPROOT/empty-home"
mkdir -p "$EMPTY_HOME"
assert_fake_home "$EMPTY_HOME"
run "execute 不带 receipts：目标不存在 退出码 1" 1 \
    plan claude-code --home "$EMPTY_HOME" --execute --no-processes
expect_contains "execute 不带 receipts 的 stderr 提示" "没有指定 --receipts"
expect_contains "空家目录找不到目标" "没有找到"

# 空计划：managedByApp 组的所有条目都因「由桌面 App 使用」被跳过，--execute 应退出码 1。
APP_HOME="$TMPROOT/app-home"
mkdir -p "$APP_HOME/Applications/CodexBar.app/Contents" "$APP_HOME/.codexbar"
cat > "$APP_HOME/Applications/CodexBar.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.steipete.codexbar</string>
<key>CFBundleName</key><string>CodexBar</string>
</dict></plist>
PLIST
printf 'data\n' > "$APP_HOME/.codexbar/state.json"
assert_fake_home "$APP_HOME"
run "execute 空计划 退出码 1" 1 \
    plan "app:com.steipete.codexbar" --home "$APP_HOME" --all --execute --no-processes
expect_contains "空计划有原因说明" "计划为空"
run "演练时空计划仍退出码 0" 0 \
    plan "app:com.steipete.codexbar" --home "$APP_HOME" --all --no-processes

# ---------- undo 的用法与读取失败 ----------
run "undo 不带 --receipts 退出码 2" 2 undo
run "undo 不存在的回执 退出码 1" 1 undo --receipts "$TMPROOT/no-such-file.json"
printf '这不是 JSON' > "$TMPROOT/bad.json"
run "undo 损坏的回执 退出码 1" 1 undo --receipts "$TMPROOT/bad.json"

# ---------- R06 依赖项：手写恶意回执 ----------
if [ "$ACM_UNDO_VALIDATION" = "1" ]; then
    printf 'secret\n' > "$TMPROOT/outside.txt"
    printf '[{"original":"%s/planted.txt","trashed":"%s/outside.txt"}]' \
        "$TMPROOT" "$TMPROOT" > "$TMPROOT/evil.json"
    run "手写回执指向废纸篓外 退出码 1" 1 undo --receipts "$TMPROOT/evil.json" --home "$HOME1"
    if [ -f "$TMPROOT/outside.txt" ] && [ ! -e "$TMPROOT/planted.txt" ]; then
        pass "恶意回执没有移动文件"
    else
        fail "恶意回执没有移动文件" "$(ls -la "$TMPROOT")"
    fi
else
    printf 'skip 手写恶意回执断言（ACM_UNDO_VALIDATION=0，等待 Uninstaller.restore 校验合入）\n'
fi

# ---------- catalog --json ----------
run "catalog --json 退出码 0" 0 catalog --json
if printf '%s' "$OUT" | python3 -m json.tool > /dev/null 2>&1; then
    pass "catalog --json 能被 python3 -m json.tool 解析"
else
    fail "catalog --json 能被 python3 -m json.tool 解析" "$OUT"
fi
if printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("products") else 1)' 2>/dev/null; then
    pass "catalog --json 含 products"
else
    fail "catalog --json 含 products"
fi

# ---------- 真正的往返：execute + undo ----------
ROUND_HOME="$TMPROOT/round-home"
mkdir -p "$ROUND_HOME/.local/bin"
printf '#!/bin/sh\necho acm-roundtrip-ok\nexit 0\n' > "$ROUND_HOME/.local/bin/claude"
chmod +x "$ROUND_HOME/.local/bin/claude"
RECEIPTS="$TMPROOT/round-receipts.json"

assert_fake_home "$ROUND_HOME"
run "往返：plan --execute 退出码 0" 0 \
    plan claude-code --home "$ROUND_HOME" --execute --receipts "$RECEIPTS" --no-processes
if [ ! -e "$ROUND_HOME/.local/bin/claude" ]; then
    pass "往返：执行后假家目录里的文件被移走"
else
    fail "往返：执行后假家目录里的文件被移走" "$(ls -la "$ROUND_HOME/.local/bin")"
fi
[ -f "$RECEIPTS" ] && pass "往返：回执已生成" || fail "往返：回执已生成"

TRASHED=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0].get("trashed") or "")' "$RECEIPTS" 2>/dev/null)
run "往返：undo 退出码 0" 0 undo --receipts "$RECEIPTS" --home "$ROUND_HOME"
if [ -x "$ROUND_HOME/.local/bin/claude" ]; then
    pass "往返：文件回到原位"
    "$ROUND_HOME/.local/bin/claude" > /dev/null 2>&1 && pass "往返：放回的文件仍可执行" || fail "往返：放回的文件仍可执行"
else
    fail "往返：文件回到原位" "$(ls -la "$ROUND_HOME/.local/bin" 2>&1)"
    TRASH_LEFTOVER="$TRASH_LEFTOVER
  ${TRASHED}（原位置 $ROUND_HOME/.local/bin/claude）"
fi
if [ -n "$TRASHED" ] && [ ! -e "$TRASHED" ]; then
    pass "往返：废纸篓里没有留下测试文件"
else
    fail "往返：废纸篓里没有留下测试文件" "还在：$TRASHED"
    TRASH_LEFTOVER="$TRASH_LEFTOVER
  $TRASHED"
fi
if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])) == [] else 1)' "$RECEIPTS" 2>/dev/null; then
    pass "往返：全部放回后回执被改写成 []"
else
    fail "往返：全部放回后回执被改写成 []" "$(cat "$RECEIPTS")"
fi

# ---------- P2：旧回执、锁定目标与相对 basename ----------
# 旧实现失败时也必须把测试假工具放回，优先取保存失败时输出的恢复 JSON。
restore_regression_tool() {
    regression_output=$OUT
    if [ ! -e "$REG_HOME/.local/bin/claude" ]; then
        printf '%s\n' "$regression_output" > "$TMPROOT/execute-output.txt"
        python3 -I -c '
import json,sys
text=open(sys.argv[1]).read()
for line in text.splitlines(keepends=True):
    if line.startswith("["):
        try:
            value,_=json.JSONDecoder().raw_decode(text[text.index(line):])
            if isinstance(value,list):
                json.dump(value,open(sys.argv[3],"w")); break
        except ValueError: pass
else:
    json.dump(json.load(open(sys.argv[2])),open(sys.argv[3],"w"))
' "$TMPROOT/execute-output.txt" "$REG_RECEIPTS" "$TMPROOT/recovery.json"
        cp "$TMPROOT/recovery.json" "$TMPROOT/recovery-before.json"
        REG_TRASHED=$(python3 -I -c 'import json,sys; print("\n".join(r.get("trashed") or "" for r in json.load(open(sys.argv[1]))))' "$TMPROOT/recovery-before.json")
        run "回归清理：放回假工具" 0 undo --receipts "$TMPROOT/recovery.json" --home "$REG_HOME"
        if [ -x "$REG_HOME/.local/bin/claude" ] && python3 -I -c 'import json,os,sys; sys.exit(0 if all(not os.path.lexists(r["trashed"]) for r in json.load(open(sys.argv[1])) if r.get("trashed")) else 1)' "$TMPROOT/recovery-before.json"; then
            pass "回归清理：全部假条目已恢复且废纸篓无遗留"
        else
            fail "回归清理：测试文件没有完全恢复" "$REG_TRASHED"
            TRASH_LEFTOVER="$TRASH_LEFTOVER
  $REG_TRASHED"
        fi
    fi
}

for receipt_case in existing locked; do
    REG_HOME="$TMPROOT/$receipt_case-home"
    REG_RECEIPTS="$TMPROOT/$receipt_case.json"
    mkdir -p "$REG_HOME/.local/bin"
    printf '#!/bin/sh\nexit 0\n' > "$REG_HOME/.local/bin/claude"
    chmod +x "$REG_HOME/.local/bin/claude"
    printf '[{"original":"%s/old","trashed":"%s/.Trash/old"}]\n' "$REG_HOME" "$REG_HOME" > "$REG_RECEIPTS"
    cp "$REG_RECEIPTS" "$TMPROOT/$receipt_case-before.json"
    if [ "$receipt_case" = locked ]; then
        chflags uchg "$REG_RECEIPTS" || { fail "设置临时回执 uchg"; exit 1; }
    fi
    run "P2 ${receipt_case}：拒绝已有回执 退出码 2" 2 \
        plan claude-code --home "$REG_HOME" --execute --receipts "$REG_RECEIPTS" --no-processes
    cmp -s "$REG_RECEIPTS" "$TMPROOT/$receipt_case-before.json" && pass "P2 ${receipt_case}：旧回执逐字保留" || fail "P2 ${receipt_case}：旧回执逐字保留"
    [ -x "$REG_HOME/.local/bin/claude" ] && pass "P2 ${receipt_case}：假工具原位" || fail "P2 ${receipt_case}：假工具原位"
    restore_regression_tool
    chflags nouchg "$REG_RECEIPTS"
done

REG_HOME="$TMPROOT/relative-home"
REG_RECEIPTS="$TMPROOT/relative.json"
mkdir -p "$REG_HOME/.local/bin"
printf '#!/bin/sh\nexit 0\n' > "$REG_HOME/.local/bin/claude"
chmod +x "$REG_HOME/.local/bin/claude"
cd "$TMPROOT"
run "P2 相对 basename：执行成功" 0 \
    plan claude-code --home "$REG_HOME" --execute --receipts relative.json --no-processes
[ -s "$REG_RECEIPTS" ] && pass "P2 相对 basename：回执存在" || fail "P2 相对 basename：回执存在"
REG_TRASHED=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[0].get("trashed") or "")' "$REG_RECEIPTS" 2>/dev/null)
run "P2 相对 basename：undo 成功" 0 undo --receipts relative.json --home "$REG_HOME"
[ -x "$REG_HOME/.local/bin/claude" ] && pass "P2 相对 basename：假工具回到原位" || fail "P2 相对 basename：假工具回到原位"
if [ -n "$REG_TRASHED" ] && [ -e "$REG_TRASHED" ]; then
    fail "P2 相对 basename：废纸篓无遗留"
    TRASH_LEFTOVER="$TRASH_LEFTOVER
  $REG_TRASHED"
fi
cd "$ROOT"

# 保存路径随被卸载的配置目录一起移走，稳定覆盖「移动成功，提交失败」。
# CLI 必须输出完整 JSON，让测试能够实际恢复全部条目。
REG_HOME="$TMPROOT/save-failure-home"
REG_RECEIPTS="$REG_HOME/.claude/r.json"
mkdir -p "$REG_HOME/.local/bin" "$REG_HOME/.claude"
printf '#!/bin/sh\nexit 0\n' > "$REG_HOME/.local/bin/claude"
chmod +x "$REG_HOME/.local/bin/claude"
printf '{}\n' > "$REG_HOME/.claude/settings.json"
run "P2 提交失败：返回失败状态" 1 \
    plan claude-code --home "$REG_HOME" --all --execute --receipts "$REG_RECEIPTS" --no-processes
expect_contains "P2 提交失败：提示手工保存恢复 JSON" "回执 JSON"
expect_not_contains "P2 提交失败：不报告写入成功" "回执已写入"
restore_regression_tool
[ -f "$REG_HOME/.claude/settings.json" ] && pass "P2 提交失败：凭输出回执恢复配置目录" || fail "P2 提交失败：凭输出回执恢复配置目录"

# 只演练、目标歧义或不存在，都不能预留文件或改写已有记录。
PREFLIGHT="$TMPROOT/preflight.json"
printf 'historical receipts\n' > "$PREFLIGHT"
cp "$PREFLIGHT" "$TMPROOT/preflight-before.json"
run "P2 歧义不覆盖历史回执" 2 plan Code --home "$HOME1" --execute --receipts "$PREFLIGHT" --no-processes
run "P2 找不到目标不覆盖历史回执" 1 plan nosuchtool --home "$HOME1" --execute --receipts "$PREFLIGHT" --no-processes
cmp -s "$PREFLIGHT" "$TMPROOT/preflight-before.json" && pass "P2 preflight：历史记录逐字保留" || fail "P2 preflight：历史记录逐字保留"
run "P2 歧义不创建回执" 2 plan Code --home "$HOME1" --execute --receipts "$TMPROOT/not-created.json" --no-processes
run "P2 找不到目标不创建回执" 1 plan nosuchtool --home "$HOME1" --execute --receipts "$TMPROOT/not-created.json" --no-processes
run "P2 仅演练不创建回执" 2 plan claude-code --home "$HOME1" --receipts "$TMPROOT/not-created.json" --no-processes
[ ! -e "$TMPROOT/not-created.json" ] && pass "P2 preflight：没有预留文件" || fail "P2 preflight：没有预留文件"
run "P2 空回执也不允许新执行覆盖" 2 plan claude-code --home "$ROUND_HOME" --execute --receipts "$RECEIPTS" --no-processes
[ -x "$ROUND_HOME/.local/bin/claude" ] && pass "P2 空回执：假工具原位" || fail "P2 空回执：假工具原位"

# ---------- undo 部分失败：剩余回执写回 ----------
PART_HOME="$TMPROOT/part-home"
mkdir -p "$PART_HOME/.Trash" "$PART_HOME/.local/bin"
printf 'data\n' > "$PART_HOME/.Trash/good.txt"
printf '[{"original":"%s/.local/bin/a","trashed":"%s/.Trash/missing.txt"},{"original":"%s/.local/bin/b","trashed":"%s/.Trash/good.txt"}]' \
    "$PART_HOME" "$PART_HOME" "$PART_HOME" "$PART_HOME" > "$TMPROOT/partial.json"
run "undo 部分失败 退出码 1" 1 undo --receipts "$TMPROOT/partial.json" --home "$PART_HOME"
expect_contains "undo 部分失败有提示可重跑" "再跑一次 undo"
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if len(d)==1 and d[0]["original"].endswith("/a") else 1)' "$TMPROOT/partial.json" 2>/dev/null; then
    pass "undo 部分失败：只剩失败那条回执"
else
    fail "undo 部分失败：只剩失败那条回执" "$(cat "$TMPROOT/partial.json")"
fi
[ -f "$PART_HOME/.local/bin/b" ] && pass "undo 部分失败：成功那条已放回" || fail "undo 部分失败：成功那条已放回"

# ---------- 汇总 ----------
printf '\n通过 %d 条，失败 %d 条\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
    printf '失败用例：%s\n' "$FAILED_NAMES"
    exit 1
fi
exit 0
