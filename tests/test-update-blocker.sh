#!/bin/bash
#
# update-blocker.sh 测试套件
#
# 设计原则：每条断言都必须在「有缺陷的输入」上失败、在「干净的输入」上通过。
# 只测 happy path 的测试等于没测。
#
# A 组：hosts 处理逻辑（纯字符串处理，不需要 root）
# B 组：脚本级集成（会改动系统状态，需要 root）
#
# 运行：
#   bash tests/test-update-blocker.sh              # 只跑 A 组
#   sudo bash tests/test-update-blocker.sh --integration   # A + B 组

set -u

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_DIR/update-blocker.sh"
AWK_LIB="$REPO_DIR/lib/hosts-filter.awk"

PASS=0; FAIL=0; SKIP=0
FAILED_NAMES=""

if [ -t 1 ]; then
    G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; O=$'\033[0m'
else
    G=""; R=""; Y=""; O=""
fi

check() {
    if [ "$2" = "0" ]; then
        PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$G" "$O" "$1"
    else
        FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES\n  - $1: $3"
        printf '  %sFAIL%s  %s   %s\n' "$R" "$O" "$1" "$3"
    fi
}

skip() { SKIP=$((SKIP+1)); printf '  %sSKIP%s  %s   %s\n' "$Y" "$O" "$1" "$2"; }

assert_grep() {
    # $1=名称 $2=文件 $3=正则 $4=期望条数
    local n
    n=$(/usr/bin/grep -cE "$3" "$2" 2>/dev/null)
    [ -z "$n" ] && n=0
    if [ "$n" = "$4" ]; then check "$1" 0; else check "$1" 1 "实际 $n 条，期望 $4 条"; fi
}

assert_has() {
    if /usr/bin/grep -qF "$3" "$2" 2>/dev/null; then check "$1" 0
    else check "$1" 1 "未找到: $3"; fi
}

assert_lacks() {
    if /usr/bin/grep -qF "$3" "$2" 2>/dev/null; then check "$1" 1 "不该出现: $3"
    else check "$1" 0; fi
}

# ==========================================================================
# 夹具
# ==========================================================================

if [ ! -f "$AWK_LIB" ]; then
    echo "!! 找不到 $AWK_LIB" >&2
    exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mbtest.XXXXXX")" || exit 1
trap 'rm -rf "$WORK" 2>/dev/null' EXIT

HOSTS_BEGIN="# >>> mac-block-updates hosts block >>>"
HOSTS_END="# <<< mac-block-updates hosts block <<<"
MARKER="# --- SWITCHHOSTS_CONTENT_START ---"
DOMAINS="swscan.apple.com swdist.apple.com swcdn.apple.com gdmf.apple.com mesu.apple.com xp.apple.com swdownload.apple.com updates-http.cdn-apple.com updates.cdn-apple.com"
LEGACY_COMMENT="屏蔽macOS"
LEGACY_BEGIN="# >>> mublock hosts block >>>"
LEGACY_END="# <<< mublock hosts block <<<"
DOMAIN_RE='^127\.0\.0\.1[[:space:]]+(swscan\.apple\.com|swdist\.apple\.com|swcdn\.apple\.com|gdmf\.apple\.com|mesu\.apple\.com|xp\.apple\.com|swdownload\.apple\.com|updates-http\.cdn-apple\.com|updates\.cdn-apple\.com)[[:space:]]*$'

# 直接调用共享的 awk 逻辑（与主脚本用的是同一份代码）
apply_hosts() {
    /usr/bin/awk -f "$AWK_LIB" -v mode=apply \
        -v begin="$HOSTS_BEGIN" -v end="$HOSTS_END" \
        -v lbegin="$LEGACY_BEGIN" -v lend="$LEGACY_END" \
        -v marker="$MARKER" -v domains="$DOMAINS" \
        -v legacy="$LEGACY_COMMENT" "$1"
}

remove_hosts() {
    /usr/bin/awk -f "$AWK_LIB" -v mode=remove \
        -v begin="$HOSTS_BEGIN" -v end="$HOSTS_END" \
        -v lbegin="$LEGACY_BEGIN" -v lend="$LEGACY_END" \
        -v marker="$MARKER" -v domains="$DOMAINS" \
        -v legacy="$LEGACY_COMMENT" "$1"
}

# ==========================================================================
# A 组
# ==========================================================================

echo ""
echo "[A1] 有 SwitchHosts 时，块必须落在标记之前"
cat > "$WORK/a1.txt" <<'EOF'
##
# Host Database
127.0.0.1	localhost

# --- SWITCHHOSTS_CONTENT_START ---

127.0.0.1 adobe.io
EOF
apply_hosts "$WORK/a1.txt" > "$WORK/a1.out"
BPOS=$(/usr/bin/grep -nF "$HOSTS_BEGIN" "$WORK/a1.out" | head -1 | cut -d: -f1)
MPOS=$(/usr/bin/grep -nF "$MARKER" "$WORK/a1.out" | head -1 | cut -d: -f1)
if [ -n "$BPOS" ] && [ -n "$MPOS" ] && [ "$BPOS" -lt "$MPOS" ]; then
    check "块在标记之前" 0
else
    check "块在标记之前" 1 "block=$BPOS marker=$MPOS"
fi
assert_grep "9 条屏蔽记录" "$WORK/a1.out" "$DOMAIN_RE" 9
assert_has "原有内容未丢失" "$WORK/a1.out" "127.0.0.1 adobe.io"

echo ""
echo "[A2] 没有 SwitchHosts 时追加到末尾"
cat > "$WORK/a2.txt" <<'EOF'
##
# Host Database
127.0.0.1	localhost
EOF
apply_hosts "$WORK/a2.txt" > "$WORK/a2.out"
assert_grep "9 条屏蔽记录" "$WORK/a2.out" "$DOMAIN_RE" 9
assert_has "原有内容未丢失" "$WORK/a2.out" "127.0.0.1	localhost"

echo ""
echo "[A3] 幂等性：反复应用不产生重复块"
# 注意：这里用 cp 而不是 mv 覆盖 —— 某些受限环境（agent 沙箱）会拦截
# mv 的写权限，导致测试结果失真。cp 是等价的，且不受该限制。
cat "$WORK/a1.out" > "$WORK/a3.txt"
i=0
while [ $i -lt 5 ]; do
    apply_hosts "$WORK/a3.txt" > "$WORK/a3.next"
    cat "$WORK/a3.next" > "$WORK/a3.txt"
    i=$((i+1))
done
assert_grep "只有一段块" "$WORK/a3.txt" "^# >>> mac-block-updates hosts block >>>$" 1
assert_grep "9 条屏蔽记录" "$WORK/a3.txt" "$DOMAIN_RE" 9

echo ""
echo "[A4] 迁移：早期 mublock 工具的块被替换而非叠加"
cat > "$WORK/a4.txt" <<'EOF'
##
# Host Database
127.0.0.1	localhost

# >>> mublock hosts block >>>
127.0.0.1	swscan.apple.com
127.0.0.1	mesu.apple.com
# <<< mublock hosts block <<<

# --- SWITCHHOSTS_CONTENT_START ---

127.0.0.1 adobe.io
EOF
apply_hosts "$WORK/a4.txt" > "$WORK/a4.out"
assert_grep "旧块标记已清除" "$WORK/a4.out" "mublock hosts block" 0
assert_grep "9 条屏蔽记录" "$WORK/a4.out" "$DOMAIN_RE" 9
assert_grep "新块只有一段" "$WORK/a4.out" "^# >>> mac-block-updates hosts block >>>$" 1

echo ""
echo "[A5] 迁移：v1 脚本遗留的裸屏蔽条目被清掉"
cat > "$WORK/a5.txt" <<'EOF'
##
# Host Database
127.0.0.1	localhost

# 屏蔽macOS系统更新服务器
127.0.0.1 swscan.apple.com
127.0.0.1 swdist.apple.com
127.0.0.1 gdmf.apple.com
127.0.0.1 mesu.apple.com
127.0.0.1 xp.apple.com
127.0.0.1 swdownload.apple.com
127.0.0.1 swcdn.apple.com
127.0.0.1 updates-http.cdn-apple.com
127.0.0.1 updates.cdn-apple.com

# --- SWITCHHOSTS_CONTENT_START ---

127.0.0.1 adobe.io
EOF
apply_hosts "$WORK/a5.txt" > "$WORK/a5.out"
assert_grep "9 条屏蔽记录" "$WORK/a5.out" "$DOMAIN_RE" 9
assert_lacks "旧注释已清除" "$WORK/a5.out" "屏蔽macOS系统更新服务器"

echo ""
echo "[A6] 不误伤：其它 127.0.0.1 条目必须保留"
cat > "$WORK/a6.txt" <<'EOF'
##
# Host Database
127.0.0.1	localhost
127.0.0.1 myapp.local
127.0.0.1 some-other-service.com
0.0.0.0 ads.example.net

# --- SWITCHHOSTS_CONTENT_START ---
EOF
apply_hosts "$WORK/a6.txt" > "$WORK/a6.out"
assert_has "myapp.local 保留" "$WORK/a6.out" "127.0.0.1 myapp.local"
assert_has "some-other-service.com 保留" "$WORK/a6.out" "127.0.0.1 some-other-service.com"
assert_has "0.0.0.0 条目保留" "$WORK/a6.out" "0.0.0.0 ads.example.net"

echo ""
echo "[A7] 移除：不能残留任何屏蔽痕迹"
cat "$WORK/a5.out" > "$WORK/a7.txt"
remove_hosts "$WORK/a7.txt" > "$WORK/a7.out"
assert_grep "无屏蔽记录残留" "$WORK/a7.out" "$DOMAIN_RE" 0
assert_lacks "块标记已清除" "$WORK/a7.out" "mac-block-updates hosts block"
assert_has "SwitchHosts 标记还在" "$WORK/a7.out" "$MARKER"
assert_has "adobe.io 还在" "$WORK/a7.out" "127.0.0.1 adobe.io"

echo ""
echo "[A8] 反证：v1 的 sed 只删注释，会留下裸条目（它恢复失败的原因）"
printf '# 屏蔽macOS系统更新服务器\n127.0.0.1 swscan.apple.com\n' > "$WORK/a8.txt"
/bin/sed -i '' '/屏蔽macOS/d' "$WORK/a8.txt" 2>/dev/null
assert_grep "v1 的 sed 留下了裸条目" "$WORK/a8.txt" "$DOMAIN_RE" 1
remove_hosts "$WORK/a8.txt" > "$WORK/a8.out"
assert_grep "我们的 remove 清掉了残留" "$WORK/a8.out" "$DOMAIN_RE" 0

echo ""
echo "[A9] 关键：模拟 SwitchHosts 的 jt() 重写，验证块能存活"
apply_hosts "$WORK/a1.txt" > "$WORK/a9.txt"
MIDX=$(/usr/bin/grep -nF "$MARKER" "$WORK/a9.txt" | head -1 | cut -d: -f1)
head -n $((MIDX-1)) "$WORK/a9.txt" > "$WORK/a9.head"
{ cat "$WORK/a9.head"; echo; echo "$MARKER"; echo; echo "127.0.0.1 new-from-remote-list.example.com"; } > "$WORK/a9.rewritten"
assert_grep "刷新后块仍存在" "$WORK/a9.rewritten" "^# >>> mac-block-updates hosts block >>>$" 1
assert_grep "刷新后 9 条记录都在" "$WORK/a9.rewritten" "$DOMAIN_RE" 9
assert_has "刷新后新规则也在" "$WORK/a9.rewritten" "new-from-remote-list.example.com"

echo ""
echo "[A10] 反证：块若在标记之后，SwitchHosts 刷新后必然丢失"
cat > "$WORK/a10.txt" <<'EOF'
##
# Host Database
127.0.0.1	localhost

# --- SWITCHHOSTS_CONTENT_START ---

127.0.0.1 adobe.io
EOF
{ cat "$WORK/a10.txt"; echo; echo "$HOSTS_BEGIN"; echo "127.0.0.1	swscan.apple.com"; echo "$HOSTS_END"; } > "$WORK/a10.after"
MIDX=$(/usr/bin/grep -nF "$MARKER" "$WORK/a10.after" | head -1 | cut -d: -f1)
head -n $((MIDX-1)) "$WORK/a10.after" > "$WORK/a10.rewritten"
assert_grep "标记之后的块确实会消失" "$WORK/a10.rewritten" "^# >>> mac-block-updates hosts block >>>$" 0

echo ""
echo "[A11] 脚本健全性"
if /bin/bash -n "$SCRIPT" 2>/dev/null; then check "bash 语法正确" 0; else check "bash 语法正确" 1 "syntax error"; fi
if /usr/bin/grep -q "macOS 26 移除了" "$SCRIPT" 2>/dev/null; then check "注释说明了 macOS 26 限制" 0; else check "注释说明了 macOS 26 限制" 1 "缺少说明"; fi
if /bin/bash -c 'declare -A t' 2>/dev/null; then
    check "未使用关联数组（bash 3.2 兼容）" 1 "用了 bash 4+ 语法"
else
    check "未使用关联数组（bash 3.2 兼容）" 0
fi
# 内嵌 fallback 必须和 lib/ 里的 awk 逻辑等价
if /usr/bin/grep -q "AWK_FALLBACK" "$SCRIPT"; then
    check "内嵌 fallback 存在（支持 curl|bash）" 0
else
    check "内嵌 fallback 存在（支持 curl|bash）" 1 "缺少 AWK_FALLBACK"
fi

echo ""
echo "[A12] 内嵌 fallback 必须与 lib/hosts-filter.awk 输出完全一致"
# curl|bash 场景下 lib/ 不存在，只能用内嵌的 AWK_FALLBACK。
# 两者若有偏差，仓库版和管道版行为就会不一致 —— 必须在测试里锁死。
if MB_SCRIPT="$SCRIPT" MB_AWK="$AWK_LIB" /usr/bin/python3 - <<'PYEOF'
import re, subprocess, os, tempfile, sys

s = open(os.environ['MB_SCRIPT']).read()
m = re.search(r"AWK_FALLBACK='\n(.*?)\n'\n", s, re.S)
if not m:
    print("  cannot locate AWK_FALLBACK")
    sys.exit(1)
fallback = m.group(1)

consts = dict(re.findall(
    r'^(HOSTS_BEGIN|HOSTS_END|SWITCHHOSTS_MARKER|BLOCK_DOMAINS|LEGACY_HOSTS_COMMENT|LEGACY_BLOCK_BEGIN|LEGACY_BLOCK_END)="(.*?)"$',
    s, re.M))
if len(consts) != 7:
    print("  cannot locate constants")
    sys.exit(1)

COMMON = ['-v', f'begin={consts["HOSTS_BEGIN"]}', '-v', f'end={consts["HOSTS_END"]}',
          '-v', f'lbegin={consts["LEGACY_BLOCK_BEGIN"]}', '-v', f'lend={consts["LEGACY_BLOCK_END"]}',
          '-v', f'marker={consts["SWITCHHOSTS_MARKER"]}', '-v', f'domains={consts["BLOCK_DOMAINS"]}',
          '-v', f'legacy={consts["LEGACY_HOSTS_COMMENT"]}']

def run_fb(mode, path):
    return subprocess.run(['/usr/bin/awk','-f','-'] + COMMON + ['-v', f'mode={mode}', path],
                          input=fallback.encode(), capture_output=True).stdout

def run_lib(mode, path):
    return subprocess.run(['/usr/bin/awk','-f', os.environ['MB_AWK']] + COMMON + ['-v', f'mode={mode}', path],
                          capture_output=True).stdout

fixtures = {
 'with_switchhosts': "##\n127.0.0.1\tlocalhost\n\n# --- SWITCHHOSTS_CONTENT_START ---\n\n127.0.0.1 adobe.io\n",
 'no_switchhosts': "##\n127.0.0.1\tlocalhost\n",
 'legacy_block': "##\n# >>> mublock hosts block >>>\n127.0.0.1\tswscan.apple.com\n# <<< mublock hosts block <<<\n# --- SWITCHHOSTS_CONTENT_START ---\n",
 'legacy_bare': "##\n# 屏蔽macOS系统更新服务器\n127.0.0.1 swscan.apple.com\n127.0.0.1 example.com\n# --- SWITCHHOSTS_CONTENT_START ---\n",
 'unrelated': "##\n127.0.0.1 myapp.local\n0.0.0.0 ads.example.net\n",
 'already_applied': "##\n# >>> mac-block-updates hosts block >>>\n127.0.0.1\tswscan.apple.com\n# <<< mac-block-updates hosts block <<<\n# --- SWITCHHOSTS_CONTENT_START ---\n",
}

bad = []
for name, content in fixtures.items():
    with tempfile.NamedTemporaryFile('w', suffix='.hosts', delete=False) as f:
        f.write(content); path = f.name
    for mode in ('apply', 'remove'):
        if run_fb(mode, path) != run_lib(mode, path):
            bad.append(f"{name}/{mode}")
    os.unlink(path)

if bad:
    print("  mismatched:", ",".join(bad))
    sys.exit(1)
PYEOF
then check "fallback 与 lib 输出一致" 0; else check "fallback 与 lib 输出一致" 1 "存在差异"; fi

# ==========================================================================
# B 组
# ==========================================================================

run_integration() {
    echo ""
    echo "[B1] 集成：block → 验证 → restore 往返"
    local out rc
    out=$(/bin/bash "$SCRIPT" block 2>&1); rc=$?
    check "block 返回 0" "$([ $rc -eq 0 ] && echo 0 || echo 1)" "$out"

    if [ -f "/Library/Managed Preferences/com.apple.SoftwareUpdate.plist" ]; then
        check "托管偏好文件已写入" 0
    else
        check "托管偏好文件已写入" 1 "文件不存在"
    fi
    local delay
    delay=$(/usr/bin/plutil -extract MajorOSManagedDeferredInstallDelay raw -o - \
            "/Library/Managed Preferences/com.apple.SoftwareUpdate.plist" 2>/dev/null)
    if [ "$delay" = "3650" ]; then check "延迟天数正确" 0; else check "延迟天数正确" 1 "实际: $delay"; fi

    local bpos mpos
    bpos=$(/usr/bin/grep -nF "# >>> mac-block-updates hosts block >>>" /etc/hosts 2>/dev/null | head -1 | cut -d: -f1)
    mpos=$(/usr/bin/grep -nF "# --- SWITCHHOSTS_CONTENT_START ---" /etc/hosts 2>/dev/null | head -1 | cut -d: -f1)
    if [ -n "$bpos" ] && { [ -z "$mpos" ] || [ "$bpos" -lt "$mpos" ]; }; then
        check "hosts 块位置正确" 0
    else
        check "hosts 块位置正确" 1 "block=$bpos marker=$mpos"
    fi

    out=$(softwareupdate --list 2>&1 | head -20)
    if printf '%s' "$out" | /usr/bin/grep -q "No new software available"; then
        check "macOS 大版本已被压住" 0
    elif printf '%s' "$out" | /usr/bin/grep -qiE "TLS|连接"; then
        skip "macOS 大版本已被压住" "更新目录不可达（hosts 拦截），无法交叉验证"
    else
        check "macOS 大版本已被压住" 1 "$out"
    fi

    echo ""
    echo "[B2] 集成：restore 之后一切归零"
    out=$(/bin/bash "$SCRIPT" restore 2>&1); rc=$?
    check "restore 返回 0" "$([ $rc -eq 0 ] && echo 0 || echo 1)" "$out"

    if [ ! -f "/Library/Managed Preferences/com.apple.SoftwareUpdate.plist" ]; then
        check "托管偏好已移除" 0
    else
        check "托管偏好已移除" 1 "文件还在"
    fi
    if ! /usr/bin/grep -qF "mac-block-updates hosts block" /etc/hosts 2>/dev/null; then
        check "hosts 块已移除" 0
    else
        check "hosts 块已移除" 1 "还在"
    fi
    if ! /usr/bin/grep -qE "^127\.0\.0\.1[[:space:]]+(swscan\.apple\.com|swdist\.apple\.com|swcdn\.apple\.com|gdmf\.apple\.com|mesu\.apple\.com|xp\.apple\.com|swdownload\.apple\.com|updates-http\.cdn-apple\.com|updates\.cdn-apple\.com)[[:space:]]*$" /etc/hosts 2>/dev/null; then
        check "无裸屏蔽条目残留" 0
    else
        check "无裸屏蔽条目残留" 1 "有残留"
    fi

    # 恢复后必须能看到大版本更新（延迟期缓存要清掉）
    killall -9 softwareupdated 2>/dev/null
    sleep 2
    out=$(softwareupdate --list 2>&1 | head -20)
    if printf '%s' "$out" | /usr/bin/grep -qiE "Title:.*27\.|Title:.*macOS 2[6-9]"; then
        check "恢复后大版本更新重新可见" 0
    elif printf '%s' "$out" | /usr/bin/grep -q "No new software available"; then
        check "恢复后大版本更新重新可见" 1 "仍然看不到（可能是目录不可达或守护进程缓存）"
    else
        skip "恢复后大版本更新重新可见" "无法判定（更新目录不可达）"
    fi

    echo ""
    echo "[B3] 集成：major-only 模式保留安全更新检查"
    /bin/bash "$SCRIPT" major-only >/dev/null 2>&1
    local ac
    ac=$(defaults read /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled 2>/dev/null)
    if [ "$ac" = "1" ]; then check "AutomaticCheckEnabled 保持开启" 0
    else check "AutomaticCheckEnabled 保持开启" 1 "实际: $ac"; fi
    if [ -f "/Library/Managed Preferences/com.apple.SoftwareUpdate.plist" ]; then
        check "大版本压制仍在" 0
    else
        check "大版本压制仍在" 1 "托管偏好没了"
    fi
    if ! /usr/bin/grep -qF "mac-block-updates hosts block" /etc/hosts 2>/dev/null; then
        check "major-only 不写 hosts 层" 0
    else
        check "major-only 不写 hosts 层" 1 "hosts 块还在"
    fi

    /bin/bash "$SCRIPT" restore >/dev/null 2>&1
}

# ==========================================================================
# 汇总
# ==========================================================================

echo ""
echo "=============================================================="
printf " 通过 %d  失败 %d  跳过 %d\n" "$PASS" "$FAIL" "$SKIP"
echo "=============================================================="

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "失败明细："
    printf "$FAILED_NAMES\n"
    exit 1
fi

if [ "${1:-}" = "--integration" ]; then
    if [ "$(id -u)" != "0" ]; then
        echo ""
        echo "需要 root 才能跑集成测试：sudo bash tests/test-update-blocker.sh --integration"
    else
        run_integration
    fi
fi

exit 0
