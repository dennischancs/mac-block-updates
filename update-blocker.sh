#!/bin/bash
#
# update-blocker.sh — macOS 系统更新屏蔽工具
#
# 一键使用：
#   curl -sSL https://cdn.jsdelivr.net/gh/dennischancs/mac-block-updates@main/install.sh | bash
#   （install.sh 会自动在多个镜像源之间回退，raw 域不通时也能装上）
#
# 核心机制（与社区方案的差异见 docs/FINDINGS.md）：
#   系统真正读取的是「托管偏好文件」，不是描述文件本体。
#   直接写 /Library/Managed Preferences/ 即可压制大版本升级，
#   不需要描述文件、不需要 GUI 确认、不需要任何第三方工具。
#
# 兼容性：macOS 12+ / 13+ / 14+ / 15 / 26 / 27
#   · macOS 26 移除了 `profiles install`，本工具不依赖它
#   · 描述文件方式在系统已存在任何描述文件时会卡在「待确认」队列，故不作为主路径
#
# 依赖：仅 macOS 自带工具（bash 3.2 / defaults / plutil / sed / awk / launchctl）
#
# 本脚本遵循 bash 3.2 语法（不使用关联数组等 bash 4+ 特性）

set -u

# ==========================================================================
# 常量
# ==========================================================================

VERSION="2.0.0"

# 托管偏好路径
MP_DIR="/Library/Managed Preferences"
MP_SOFTWAREUPDATE="$MP_DIR/com.apple.SoftwareUpdate.plist"
MP_APPLICATIONACCESS="$MP_DIR/com.apple.applicationaccess.plist"
MP_SETUPASSISTANT="$MP_DIR/com.apple.SetupAssistant.managed.plist"

# 系统域偏好
SU_DOMAIN="/Library/Preferences/com.apple.SoftwareUpdate"

# hosts 文件
HOSTS_FILE="/etc/hosts"

# 我们的 hosts 块标记
HOSTS_BEGIN="# >>> mac-block-updates hosts block >>>"
HOSTS_END="# <<< mac-block-updates hosts block <<<"

# SwitchHosts 的接管标记。它的重写逻辑只保留此标记【之前】的内容，
# 标记之后的内容每次刷新都会被丢弃 —— 所以屏蔽块必须放在标记之前。
SWITCHHOSTS_MARKER="# --- SWITCHHOSTS_CONTENT_START ---"

# 需要拦截的更新服务器
BLOCK_DOMAINS="swscan.apple.com swdist.apple.com swcdn.apple.com gdmf.apple.com mesu.apple.com xp.apple.com swdownload.apple.com updates-http.cdn-apple.com updates.cdn-apple.com"
LEGACY_BEGIN="# >>> mublock hosts block >>>"
LEGACY_END="# <<< mublock hosts block <<<"
LEGACY_COMMENT="屏蔽macOS"

# 需要关闭的自动更新开关
SU_FLAGS="AutomaticCheckEnabled AutomaticDownload AutomaticallyInstallMacOSUpdates ConfigDataInstall CriticalUpdateInstall"

# 延迟天数上限（实测 3650 天被系统接受并生效）
DEFAULT_DELAY=3650

# 状态文件：记录改动前的原值，供恢复时精确还原
STATE_DIR="/var/db/mac-block-updates"
STATE_FILE="$STATE_DIR/state"

# launchd 复查任务
LAUNCHD_LABEL="local.mac-block-updates.watch"
LAUNCHD_PLIST="/Library/LaunchDaemons/$LAUNCHD_LABEL.plist"
LAUNCHD_SCRIPT="/usr/local/libexec/mac-block-updates-watch"

# 旧版脚本留下的痕迹（用于迁移清理）
LEGACY_HOSTS_COMMENT="屏蔽macOS"
# 早期 mublock 工具用的块标记（升级时需要一并清掉）
LEGACY_BLOCK_BEGIN="# >>> mublock hosts block >>>"
LEGACY_BLOCK_END="# <<< mublock hosts block <<<"

# hosts 处理逻辑。优先用仓库里的 lib/hosts-filter.awk；
# 管道安装（curl | bash）时该文件不存在 → 用内嵌的 AWK_FALLBACK。
AWK_FILE=""
AWK_FALLBACK='
function emit_block(    i, d, n2) {
    n2 = split(domains, dd, " ")
    print begin
    for (i = 1; i <= n2; i++) if (dd[i] != "") printf "127.0.0.1\t%s\n", dd[i]
    print end
}
function is_target_domain(    i) {
    for (i = 2; i <= NF; i++) { if ($i in target) return 1 }
    return 0
}
BEGIN {
    in_block = 0; inserted = 0
    n = split(domains, doms, " ")
    for (i = 1; i <= n; i++) if (doms[i] != "") target[doms[i]] = 1
    if (mode == "") mode = "apply"
}
index($0, begin) > 0  { in_block = 1; next }
index($0, end) > 0    { in_block = 0; next }
index($0, lbegin) > 0 { in_block = 1; next }
index($0, lend) > 0   { in_block = 0; next }
in_block == 1 { next }
{
    if ($1 == "127.0.0.1" || $1 == "0.0.0.0") { if (is_target_domain()) next }
    if (index($0, legacy) > 0 && index($0, "#") == 1) next
    if (mode == "apply" && inserted == 0 && index($0, marker) > 0) {
        emit_block(); print ""; inserted = 1
    }
    print
}
END {
    if (mode == "apply" && inserted == 0) { print ""; emit_block() }
}
'

# ==========================================================================
# 输出helpers
# ==========================================================================

if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_OFF=""
fi

say()  { printf "%s\n" "$*"; }
info() { printf "%s\n" "$*"; }
ok()   { printf "${C_GRN}[ok]${C_OFF} %s\n" "$*"; }
warn() { printf "${C_YEL}[warn]${C_OFF} %s\n" "$*" >&2; }
err()  { printf "${C_RED}[fail]${C_OFF} %s\n" "$*" >&2; }
step() { printf "${C_BLU}==>${C_OFF} %s\n" "$*"; }
dim()  { printf "${C_DIM}%s${C_OFF}\n" "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }

# ==========================================================================
# 提权
# ==========================================================================

is_root() { [ "$(id -u)" = "0" ]; }

# 需要 root。以文件方式运行时自动用 sudo 提权重跑；
# 管道方式（curl | bash）则要求调用方自带 sudo。
ensure_root() {
    is_root && return 0

    if [ -n "${MUBLOCK_SCRIPT_PATH:-}" ] && [ -f "${MUBLOCK_SCRIPT_PATH}" ]; then
        step "需要管理员权限，正在请求授权…"
        exec sudo /bin/bash "${MUBLOCK_SCRIPT_PATH}" "$@"
    fi

    err "需要管理员权限。"
    err "管道安装请用：curl -sSL <url> | sudo bash"
    err "或把脚本下载下来后运行：sudo bash update-blocker.sh"
    exit 1
}

# ==========================================================================
# 工具函数
# ==========================================================================

macos_version() {
    sw_vers -productVersion 2>/dev/null || echo "unknown"
}

# 判断 macOS 主版本号
macos_major() {
    macos_version | cut -d. -f1
}

# 读取托管偏好里的某个键（返回整数值，无则返回空）
mp_get() {
    # $1 = plist 路径, $2 = 键名
    [ -f "$1" ] || return 1
    /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

# 写一个 plist（从 stdin 读 XML）
# $1 = 目标路径
write_plist() {
    local target="$1" tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/mb.XXXXXX")" || return 1
    cat > "$tmp"
    if ! /usr/bin/plutil -lint "$tmp" >/dev/null 2>&1; then
        /bin/rm -f "$tmp"
        err "生成的 plist 校验失败：$target"
        return 1
    fi
    # 用 install 而不是 cp：能正确设置属主与权限
    if ! /usr/bin/install -m 644 -o root -g wheel "$tmp" "$target" 2>/dev/null; then
        /bin/rm -f "$tmp"
        err "写入失败：$target"
        return 1
    fi
    /bin/rm -f "$tmp"
    return 0
}

# 记录改动前的原值
state_save() {
    local key="$1" value="$2"
    [ -f "$STATE_FILE" ] || return 0
    # 同一 key 只记第一次
    if ! grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
        printf '%s=%s\n' "$key" "$value" >> "$STATE_FILE"
    fi
}

state_get() {
    local key="$1"
    [ -f "$STATE_FILE" ] || return 1
    grep "^${key}=" "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2-
}

# ==========================================================================
# hosts 层
# ==========================================================================

# hosts 里是否已有我们的块
hosts_has_block() {
    grep -qF "$HOSTS_BEGIN" "$HOSTS_FILE" 2>/dev/null
}

# 我们的块相对 SwitchHosts 标记的位置：before / after / none
hosts_block_position() {
    if ! hosts_has_block; then
        echo "none"
        return
    fi
    local bpos mpos
    bpos=$(grep -nF "$HOSTS_BEGIN" "$HOSTS_FILE" 2>/dev/null | head -1 | cut -d: -f1)
    mpos=$(grep -nF "$SWITCHHOSTS_MARKER" "$HOSTS_FILE" 2>/dev/null | head -1 | cut -d: -f1)
    if [ -z "$mpos" ]; then
        echo "before"   # 没有 SwitchHosts，尾部追加也没问题
    elif [ "$bpos" -lt "$mpos" ]; then
        echo "before"
    else
        echo "after"
    fi
}

# 生成我们的块内容
hosts_block_content() {
    local d
    printf '%s\n' "$HOSTS_BEGIN"
    for d in $BLOCK_DOMAINS; do
        printf '127.0.0.1\t%s\n' "$d"
    done
    printf '%s\n' "$HOSTS_END"
}

# 把屏蔽块写进 /etc/hosts
# 规则：
#   1) 先删掉已有的块（含旧版脚本遗留的裸条目），保证幂等
#   2) 若存在 SwitchHosts 标记，插到标记【之前】
#   3) 否则追加到文件末尾
# 定位 awk 逻辑文件：优先用仓库里的 lib/hosts-filter.awk，
# 管道安装（curl | bash）时该文件不存在 → 用内嵌的 AWK_FALLBACK。
resolve_awk() {
    if [ -n "$AWK_FILE" ]; then return 0; fi
    local dir
    dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
    if [ -n "$dir" ] && [ -f "$dir/lib/hosts-filter.awk" ]; then
        AWK_FILE="$dir/lib/hosts-filter.awk"
        return 0
    fi
    return 1
}

# 把屏蔽块写进 /etc/hosts
# 规则：
#   1) 先删掉已有的块（含 v1 脚本残留的裸条目），保证幂等
#   2) 若存在 SwitchHosts 标记，插到标记【之前】
#   3) 否则追加到文件末尾
hosts_apply() {
    hosts_filter apply
}

# 移除屏蔽块（同时清理 v1 脚本残留）
hosts_remove() {
    hosts_filter remove
}

# 共用的 hosts 重写逻辑
# $1 = apply | remove
hosts_filter() {
    local mode="$1" tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/mb.hosts.XXXXXX")" || return 1

    local -a AWK_ARGS
    AWK_ARGS=(
        -v mode="$mode"
        -v begin="$HOSTS_BEGIN"
        -v end="$HOSTS_END"
        -v lbegin="$LEGACY_BLOCK_BEGIN"
        -v lend="$LEGACY_BLOCK_END"
        -v marker="$SWITCHHOSTS_MARKER"
        -v domains="$BLOCK_DOMAINS"
        -v legacy="$LEGACY_HOSTS_COMMENT"
    )

    if resolve_awk; then
        awk -f "$AWK_FILE" "${AWK_ARGS[@]}" "$HOSTS_FILE" > "$tmp" 2>/dev/null
    else
        # bash 3.2 没有关联数组，但支持普通数组展开
        printf '%s\n' "$AWK_FALLBACK" | awk -f - "${AWK_ARGS[@]}" "$HOSTS_FILE" > "$tmp" 2>/dev/null
    fi

    if [ ! -s "$tmp" ]; then
        /bin/rm -f "$tmp"
        err "处理 $HOSTS_FILE 失败"
        return 1
    fi

    if ! /usr/bin/install -m 644 -o root -g wheel "$tmp" "$HOSTS_FILE" 2>/dev/null; then
        /bin/rm -f "$tmp"
        err "写入 $HOSTS_FILE 失败"
        return 1
    fi
    /bin/rm -f "$tmp"
    return 0
}


flush_resolver() {
    dscacheutil -flushcache 2>/dev/null
    killall -HUP mDNSResponder 2>/dev/null
    return 0
}

# ==========================================================================
# 托管偏好层（核心生效机制）
# ==========================================================================

# 写 com.apple.SoftwareUpdate 托管偏好
# 这是实测唯一必需的一层：写进去就能压制大版本升级。
write_mp_softwareupdate() {
    local delay="$1"
    write_plist "$MP_SOFTWAREUPDATE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>forceDelayedMajorSoftwareUpdates</key>
    <true/>
    <key>MajorOSManagedDeferredInstallDelay</key>
    <integer>$delay</integer>
    <key>AutomaticCheckEnabled</key>
    <false/>
    <key>AutomaticDownload</key>
    <false/>
    <key>AutomaticallyInstallMacOSUpdates</key>
    <false/>
    <key>CriticalUpdateInstall</key>
    <false/>
    <key>ConfigDataInstall</key>
    <false/>
    <key>AutoInstallProductKeys</key>
    <array/>
</dict>
</plist>
EOF
}

# 写 com.apple.applicationaccess 托管偏好
# 这是 MDM 描述文件下发时用的域。macOS 26 上系统自己也是写这两个域，
# 两者都写保证跨版本一致。
write_mp_applicationaccess() {
    local delay="$1"
    write_plist "$MP_APPLICATIONACCESS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>forceDelayedMajorSoftwareUpdates</key>
    <true/>
    <key>enforcedSoftwareUpdateMajorOSDeferredInstallDelay</key>
    <integer>$delay</integer>
</dict>
</plist>
EOF
}

# 写 com.apple.SetupAssistant.managed 托管偏好（消除小红点）
write_mp_setupassistant() {
    write_plist "$MP_SETUPASSISTANT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>SkipSetupItems</key>
    <array>
        <string>SoftwareUpdate</string>
        <string>UpdateCompleted</string>
    </array>
</dict>
</plist>
EOF
}

# 延迟是否生效
deferral_active() {
    local v
    v=$(mp_get "$MP_SOFTWAREUPDATE" "MajorOSManagedDeferredInstallDelay" 2>/dev/null)
    [ -n "$v" ] || return 1
    [ "$(mp_get "$MP_SOFTWAREUPDATE" "forceDelayedMajorSoftwareUpdates" 2>/dev/null)" = "true" ]
}

deferral_days() {
    mp_get "$MP_SOFTWAREUPDATE" "MajorOSManagedDeferredInstallDelay" 2>/dev/null
}

badge_suppressed() {
    [ -f "$MP_SETUPASSISTANT" ] || return 1
    /usr/bin/plutil -extract SkipSetupItems json -o - "$MP_SETUPASSISTANT" 2>/dev/null | grep -q "SoftwareUpdate"
}

# ==========================================================================
# 系统域偏好
# ==========================================================================

prefs_record_original() {
    local f v
    mkdir -p "$STATE_DIR" 2>/dev/null
    for f in $SU_FLAGS; do
        v=$(defaults read "$SU_DOMAIN" "$f" 2>/dev/null)
        [ -n "$v" ] || v="__unset__"
        state_save "prefs_$f" "$v"
    done
}

# 设置系统域开关。$1 = true/false
prefs_set() {
    local want="$1" f
    for f in $SU_FLAGS; do
        defaults write "$SU_DOMAIN" "$f" -bool "$want" 2>/dev/null
    done
}

prefs_restore() {
    local f v
    for f in $SU_FLAGS; do
        v=$(state_get "prefs_$f")
        if [ -z "$v" ] || [ "$v" = "__unset__" ]; then
            # 原值是"未设置" → 删掉这个键。
            # 注意：不要删整个 domain 文件——那会连带清掉 macOS 自己的其它状态。
            defaults delete "$SU_DOMAIN" "$f" 2>/dev/null
        else
            defaults write "$SU_DOMAIN" "$f" -bool "$v" 2>/dev/null
        fi
    done
}

# 只关掉"自动安装 macOS"，其余保持原样（保留安全更新）
prefs_allow_security_updates() {
    local f v
    for f in $SU_FLAGS; do
        v=$(defaults read "$SU_DOMAIN" "$f" 2>/dev/null)
        case "$f" in
            AutomaticallyInstallMacOSUpdates)
                # 绝不自动安装 macOS 大版本
                defaults write "$SU_DOMAIN" "$f" -bool false 2>/dev/null ;;
            AutomaticCheckEnabled|AutomaticDownload)
                # 保持原值；未设置时打开检查（这样次要/安全更新能正常收到）
                [ -n "$v" ] || defaults write "$SU_DOMAIN" "$f" -bool true 2>/dev/null ;;
            *)
                [ -n "$v" ] || defaults write "$SU_DOMAIN" "$f" -bool true 2>/dev/null ;;
        esac
    done
    softwareupdate --schedule on >/dev/null 2>&1
}

# ==========================================================================
# 动作
# ==========================================================================

# 屏蔽所有更新
action_block_all() {
    local delay="${1:-$DEFAULT_DELAY}"
    step "正在屏蔽 macOS 系统更新（延迟 $delay 天）…"

    prefs_record_original
    write_mp_softwareupdate "$delay" || return 1
    write_mp_applicationaccess "$delay" || return 1
    write_mp_setupassistant || return 1
    ok "托管偏好已写入（大版本升级已压制 + 小红点已压制）"

    prefs_set false
    softwareupdate --schedule off >/dev/null 2>&1
    ok "自动检查/下载/安装已关闭"

    if hosts_apply; then
        ok "hosts 屏蔽块已写入"
    else
        warn "hosts 写入失败（不影响主机制）"
    fi
    flush_resolver

    # 清理已下载的更新包
    /bin/rm -rf /Library/Updates/* 2>/dev/null

    ok "✅ 屏蔽完成"
    echo ""
    action_status
    return 0
}

# 只屏蔽大版本，保留安全更新
action_major_only() {
    local delay="${1:-$DEFAULT_DELAY}"
    step "正在设置为：只屏蔽大版本升级，保留次要/安全更新…"

    prefs_record_original
    write_mp_softwareupdate "$delay" || return 1
    write_mp_applicationaccess "$delay" || return 1
    write_mp_setupassistant || return 1
    ok "大版本升级已压制（延迟 $delay 天），小红点已压制"

    # 关键：不写 hosts 层，且明确打开自动检查 —— 这样次要/安全更新照常能收到
    prefs_allow_security_updates
    # 显式确认（不依赖"原值是否为空"的判断），确保检查是开着的
    defaults write "$SU_DOMAIN" AutomaticCheckEnabled -bool true 2>/dev/null
    defaults write "$SU_DOMAIN" AutomaticDownload -bool true 2>/dev/null
    ok "自动检查已开启，次要与安全更新照常可用"

    flush_resolver
    ok "✅ 设置完成"
    echo ""
    action_status
    return 0
}

# 只清小红点
action_badge() {
    step "正在清除更新小红点…"

    write_mp_setupassistant || return 1
    ok "已写入 SkipSetupItems（跳过软件更新引导页）"

    # 顺带清掉本地缓存的更新提示
    /bin/rm -rf ~/Library/Caches/com.apple.preferences.softwareupdate 2>/dev/null
    /bin/rm -rf /Library/Caches/com.apple.softwareupdate 2>/dev/null
    /bin/rm -rf /private/var/db/com.apple.softwareupdate 2>/dev/null

    killall -9 softwareupdated 2>/dev/null
    killall Dock 2>/dev/null

    ok "✅ 小红点已清除（若仍显示，重启电脑或系统设置后重试）"
    return 0
}

# 把托管偏好置为中性状态（明确关闭延迟）。
#
# ⚠️ 关键（实测踩到）：
# 只把托管偏好文件【删掉】是不够的！macOS 的 softwareupdated 会保留
# 之前的判定缓存，导致恢复后 softwareupdate --list 仍然看不到
# macOS 大版本（实测：删文件 → 仍不可见；写入 forceDelayed=false
# → 立刻重新可见）。所以必须显式写入"关闭"的值。
#
# 另外，某些受限环境（沙箱 / 安全软件）会拦截对
# /Library/Managed Preferences 的 unlink，而 install 覆盖总是可行。
neutralize_managed_prefs() {
    local tmp f
    tmp="$(mktemp "${TMPDIR:-/tmp}/mb.neutral.XXXXXX")" || return 1
    cat > "$tmp" <<'NEUTRAL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>forceDelayedMajorSoftwareUpdates</key>
    <false/>
    <key>MajorOSManagedDeferredInstallDelay</key>
    <integer>0</integer>
</dict>
</plist>
NEUTRAL
    for f in "$MP_SOFTWAREUPDATE" "$MP_APPLICATIONACCESS"; do
        /usr/bin/install -m 644 -o root -g wheel "$tmp" "$f" 2>/dev/null
    done
    # 小红点：写空数组 = 不跳过任何引导项 = 恢复正常
    cat > "$tmp" <<'NEUTRAL2'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>SkipSetupItems</key>
    <array/>
</dict>
</plist>
NEUTRAL2
    /usr/bin/install -m 644 -o root -g wheel "$tmp" "$MP_SETUPASSISTANT" 2>/dev/null
    /bin/rm -f "$tmp" 2>/dev/null
    return 0
}

# 恢复
action_restore() {
    step "正在恢复系统更新…"

    # 移除托管偏好：写入明确关闭的中性值（只删文件不够，见 neutralize_managed_prefs 注释）
    neutralize_managed_prefs
    if deferral_active; then
        warn "托管偏好未能完全清除（系统仍可能压制大版本升级），请手动检查"
    else
        ok "托管偏好已置为中性（大版本升级不再被压制）"
    fi

    # 还原系统域偏好
    prefs_restore
    softwareupdate --schedule on >/dev/null 2>&1
    ok "系统域偏好已还原为改动前的值"

    # 移除 hosts 屏蔽块
    if hosts_remove; then
        ok "hosts 屏蔽块已移除"
    else
        warn "hosts 清理失败"
    fi
    flush_resolver

    # 重新启用后台更新服务，并重启它以清掉延迟期的缓存。
    # 不重启的话，softwareupdated 守护进程可能还记着"被压制"的状态，
    # 导致恢复后 softwareupdate --list 仍然看不到应有的更新。
    launchctl enable system/com.apple.softwareupdated 2>/dev/null
    # 重启 cfprefsd（让它重新读托管偏好）和 softwareupdated
    # （让它丢掉延迟期缓存，重新评估可更新列表）
    killall cfprefsd 2>/dev/null
    killall -9 softwareupdated 2>/dev/null

    /bin/rm -rf "$STATE_DIR" 2>/dev/null

    ok "✅ 恢复完成"
    echo ""
    dim "提示：macOS 26 上「设置 → 通用 → 软件更新」里的自动更新开关可能仍需手动确认一次。"
    return 0
}

# 状态
action_status() {
    local d v pos
    say ""
    say "=============================================================="
    say " macOS 更新屏蔽状态   macOS $(macos_version)"
    say "=============================================================="

    say ""
    say "[1] 托管偏好（核心：压制大版本升级）"
    if deferral_active; then
        ok "已生效，延迟 $(deferral_days) 天"
    else
        warn "未生效"
    fi
    if badge_suppressed; then
        ok "小红点压制已生效（SkipSetupItems）"
    else
        warn "小红点压制未生效"
    fi

    say ""
    say "[2] hosts 层（网络层拦截）"
    pos=$(hosts_block_position)
    case "$pos" in
        before) ok "屏蔽块在位，且位于 SwitchHosts 标记之前（刷新后仍存活）" ;;
        after)  warn "屏蔽块在位但位置错误 —— SwitchHosts 刷新后会抹掉，请重跑一次" ;;
        none)   warn "屏蔽块不存在" ;;
    esac

    say ""
    say "[3] 系统域偏好"
    for d in $SU_FLAGS; do
        v=$(defaults read "$SU_DOMAIN" "$d" 2>/dev/null)
        case "$v" in
            0|false) printf '    %-32s %s\n' "$d" "关闭" ;;
            1|true)  printf '    %-32s %s\n' "$d" "开启" ;;
            *)        printf '    %-32s %s\n' "$d" "未设置" ;;
        esac
    done

    say ""
    say "[4] 定期复查"
    if [ -f "$LAUNCHD_PLIST" ]; then
        ok "已启用（每小时检查一次，异常自动修复）"
    else
        dim "    未启用。想要自动修复请运行：sudo bash update-blocker.sh watch --install"
    fi
    say ""
    return 0
}

# 验证
action_verify() {
    local pending
    say "=== macOS 更新屏蔽验证 ==="
    say "macOS $(macos_version)"
    say ""

    if deferral_active; then
        ok "大版本升级压制：已生效（延迟 $(deferral_days) 天）"
    else
        err "大版本升级压制：未生效"
    fi

    if badge_suppressed; then
        ok "小红点压制：已生效"
    else
        warn "小红点压制：未生效"
    fi

    pos=$(hosts_block_position)
    if [ "$pos" = "before" ]; then
        ok "hosts 屏蔽块：在位且位置正确"
    elif [ "$pos" = "after" ]; then
        warn "hosts 屏蔽块：位置错误（SwitchHosts 刷新后会抹掉）"
    else
        warn "hosts 屏蔽块：不存在"
    fi

    say ""
    say "实际效果（softwareupdate --list，最多等 20 秒）…"
    pending=$(softwareupdate --list 2>&1 | head -20)
    if printf '%s' "$pending" | grep -q "No new software available"; then
        ok "当前没有可用的系统更新"
    elif printf '%s' "$pending" | grep -qiE "Title:.*macOS 2[6-9]|Title:.*Sequoia|Title:.*Tahoe"; then
        err "仍能看到大版本升级："
        printf '%s\n' "$pending" | grep -i "Title:" | sed 's/^/      /'
    else
        dim "无法判定（更新目录不可达，可能是 hosts 层在拦截）"
    fi

    say ""
    if deferral_active; then
        ok "结论：屏蔽生效"
        return 0
    else
        err "结论：屏蔽未生效"
        return 1
    fi
}

# 彻底卸载
action_uninstall() {
    step "正在卸载 mac-block-updates…"

    action_restore >/dev/null 2>&1
    watch_uninstall
    /bin/rm -f "$LAUNCHD_SCRIPT" 2>/dev/null
    /bin/rm -f /usr/local/libexec/mac-block-updates-hosts-filter.awk 2>/dev/null
    /bin/rm -rf "$STATE_DIR" 2>/dev/null
    ok "✅ 已完全卸载"
    return 0
}

# ==========================================================================
# 定期复查（launchd）
# ==========================================================================

watch_install() {
    step "正在安装定期复查任务（每小时一次）…"

    mkdir -p /usr/local/libexec 2>/dev/null
    cat > "$LAUNCHD_SCRIPT" <<'WATCHEOF'
#!/bin/bash
# mac-block-updates 定期复查脚本（由 launchd 周期调用）
# 职责：检查托管偏好与 hosts 屏蔽块是否还在，掉了就补回去。
LOG="/var/log/mac-block-updates.log"
STAMP="$(date '+%Y-%m-%d %H:%M:%S')"

MP_SW="/Library/Managed Preferences/com.apple.SoftwareUpdate.plist"
MP_AA="/Library/Managed Preferences/com.apple.applicationaccess.plist"
MP_SA="/Library/Managed Preferences/com.apple.SetupAssistant.managed.plist"
HOSTS="/etc/hosts"
BEGIN="# >>> mac-block-updates hosts block >>>"
END="# <<< mac-block-updates hosts block <<<"
MARKER="# --- SWITCHHOSTS_CONTENT_START ---"
DOMAINS="swscan.apple.com swdist.apple.com swcdn.apple.com gdmf.apple.com mesu.apple.com xp.apple.com swdownload.apple.com updates-http.cdn-apple.com updates.cdn-apple.com"
LEGACY_BEGIN="# >>> mublock hosts block >>>"
LEGACY_END="# <<< mublock hosts block <<<"
LEGACY_COMMENT="屏蔽macOS"
FIXED=0

log() { printf '%s %s\n' "$STAMP" "$1" >> "$LOG" 2>/dev/null; }

# 1) 托管偏好还在吗
if [ ! -f "$MP_SW" ]; then
    log "托管偏好丢失，重新写入"
    mkdir -p "/Library/Managed Preferences" 2>/dev/null
    cat > "$MP_SW" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>forceDelayedMajorSoftwareUpdates</key><true/>
    <key>MajorOSManagedDeferredInstallDelay</key><integer>3650</integer>
    <key>AutomaticCheckEnabled</key><false/>
    <key>AutomaticDownload</key><false/>
    <key>AutomaticallyInstallMacOSUpdates</key><false/>
    <key>CriticalUpdateInstall</key><false/>
    <key>ConfigDataInstall</key><false/>
    <key>AutoInstallProductKeys</key><array/>
</dict>
</plist>
EOF
    chown root:wheel "$MP_SW" 2>/dev/null; chmod 644 "$MP_SW" 2>/dev/null
    FIXED=1
fi
if [ ! -f "$MP_SA" ]; then
    mkdir -p "/Library/Managed Preferences" 2>/dev/null
    cat > "$MP_SA" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>SkipSetupItems</key>
    <array><string>SoftwareUpdate</string><string>UpdateCompleted</string></array>
</dict>
</plist>
EOF
    chown root:wheel "$MP_SA" 2>/dev/null; chmod 644 "$MP_SA" 2>/dev/null
    FIXED=1
fi

# 2) hosts 屏蔽块还在吗 / 位置对吗
HAS=0
if grep -qF "$BEGIN" "$HOSTS" 2>/dev/null; then HAS=1; fi
BPOS=$(grep -nF "$BEGIN" "$HOSTS" 2>/dev/null | head -1 | cut -d: -f1)
MPOS=$(grep -nF "$MARKER" "$HOSTS" 2>/dev/null | head -1 | cut -d: -f1)
NEED=0
if [ "$HAS" = "0" ]; then NEED=1; else
    if [ -n "$MPOS" ] && [ -n "$BPOS" ] && [ "$BPOS" -ge "$MPOS" ]; then NEED=1; fi
fi
if [ "$NEED" = "1" ]; then
    log "hosts 屏蔽块缺失或位置错误，重新写入"
    # 用与主脚本同一份 awk 逻辑（lib/hosts-filter.awk），
    # 保证复查时写入的块与主脚本格式完全一致。
    AWKF="/usr/local/libexec/mac-block-updates-hosts-filter.awk"
    if [ ! -f "$AWKF" ]; then
        AWKF="/Library/Application Support/mac-block-updates/hosts-filter.awk"
    fi
    if [ -f "$AWKF" ]; then
        awk -f "$AWKF" -v mode=apply -v begin="$BEGIN" -v end="$END" \
            -v lbegin="$LEGACY_BEGIN" -v lend="$LEGACY_END" \
            -v marker="$MARKER" -v domains="$DOMAINS" -v legacy="$LEGACY_COMMENT" \
            "$HOSTS" > /tmp/mb_watch_hosts.$$ 2>/dev/null
    else
        awk -v mode=apply -v begin="$BEGIN" -v end="$END" \
            -v lbegin="$LEGACY_BEGIN" -v lend="$LEGACY_END" \
            -v marker="$MARKER" -v domains="$DOMAINS" -v legacy="$LEGACY_COMMENT" \
            'function is_td(    i){for(i=2;i<=NF;i++) if($i in t) return 1; return 0}
             BEGIN{ib=0;ins=0;n=split(domains,d," ");for(i=1;i<=n;i++) if(d[i]!="") t[d[i]]=1}
             index($0,begin)>0{ib=1;next} index($0,end)>0{ib=0;next}
             index($0,lbegin)>0{ib=1;next} index($0,lend)>0{ib=0;next}
             ib==1{next}
             { if($1=="127.0.0.1"||$1=="0.0.0.0"){ if(is_td()) next }
               if(index($0,legacy)>0 && index($0,"#")==1) next
               if(ins==0 && index($0,marker)>0){ print begin
                   for(i=1;i<=n;i++) if(d[i]!="") printf "127.0.0.1\t%s\n", d[i]
                   print end; print ""; ins=1 }
               print }
             END{ if(ins==0){ print ""; print begin
                   for(i=1;i<=n;i++) if(d[i]!="") printf "127.0.0.1\t%s\n", d[i]
                   print end } }' \
            "$HOSTS" > /tmp/mb_watch_hosts.$$ 2>/dev/null
    fi
    if [ -s /tmp/mb_watch_hosts.$$ ]; then
        install -m 644 -o root -g wheel /tmp/mb_watch_hosts.$$ "$HOSTS" 2>/dev/null
    fi
    /bin/rm -f /tmp/mb_watch_hosts.$$ 2>/dev/null
    FIXED=1
fi

if [ "$FIXED" = "1" ]; then
    dscacheutil -flushcache 2>/dev/null
    killall -HUP mDNSResponder 2>/dev/null
    log "已修复"
else
    log "一切正常"
fi
WATCHEOF
    chmod 755 "$LAUNCHD_SCRIPT" 2>/dev/null

    # 把共享的 hosts 处理逻辑一并装上，供复查脚本使用
    if resolve_awk; then
        mkdir -p /usr/local/libexec 2>/dev/null
        install -m 644 -o root -g wheel "$AWK_FILE" \
            /usr/local/libexec/mac-block-updates-hosts-filter.awk 2>/dev/null
    fi

    cat > "$LAUNCHD_PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LAUNCHD_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$LAUNCHD_SCRIPT</string>
    </array>
    <key>StartInterval</key>
    <integer>3600</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/var/log/mac-block-updates.log</string>
</dict>
</plist>
PLISTEOF
    chmod 644 "$LAUNCHD_PLIST" 2>/dev/null

    launchctl unload "$LAUNCHD_PLIST" 2>/dev/null
    launchctl load "$LAUNCHD_PLIST" 2>/dev/null
    if [ -f "$LAUNCHD_PLIST" ]; then
        ok "定期复查已启用（每小时一次，异常自动修复）"
        dim "    日志：/var/log/mac-block-updates.log"
    else
        warn "launchd 加载失败，可稍后手动执行：launchctl load $LAUNCHD_PLIST"
    fi
    return 0
}

watch_uninstall() {
    if [ -f "$LAUNCHD_PLIST" ]; then
        launchctl unload "$LAUNCHD_PLIST" 2>/dev/null
        /bin/rm -f "$LAUNCHD_PLIST" 2>/dev/null
        ok "定期复查已停用"
    fi
    return 0
}

# ==========================================================================
# 图形菜单
# ==========================================================================

gui_menu() {
    local choice
    if ! have osascript; then
        err "当前环境不支持图形菜单，请使用命令行参数（见 --help）"
        return 1
    fi

    choice=$(osascript <<'EOF' 2>/dev/null
set options to {"🔒 屏蔽所有系统更新", "🛡️ 只屏蔽大版本，保留安全更新", "🧹 清除更新小红点", "🔓 恢复系统更新", "📊 查看当前状态"}
set r to choose from list options with title "macOS 更新屏蔽工具" with prompt "选择一个操作：" default items {"📊 查看当前状态"}
if r is false then return "" 
return item 1 of r
EOF
)

    if [ -z "$choice" ]; then
        say ""
        say "已取消。"
        return 0
    fi

    say ""
    case "$choice" in
        *"屏蔽所有系统更新"*)  action_block_all ;;
        *"只屏蔽大版本"*)        action_major_only ;;
        *"清除更新小红点"*)      action_badge ;;
        *"恢复系统更新"*)        action_restore ;;
        *"查看当前状态"*)        action_status ;;
    esac
    return 0
}

# ==========================================================================
# 帮助
# ==========================================================================

show_help() {
    cat <<EOF
macOS 系统更新屏蔽工具  v$VERSION

用法：
  update-blocker.sh [命令] [参数]

命令：
  (无参数)              打开图形菜单选择操作
  block [天数]          屏蔽所有系统更新（默认延迟 ${DEFAULT_DELAY} 天）
  major-only [天数]     只屏蔽大版本升级，保留次要/安全更新
  badge                 只清除系统设置里的更新小红点
  restore               恢复系统更新
  status                查看当前各层状态
  verify                验证屏蔽是否真的生效
  watch --install       启用每小时自动复查（异常自动修复）
  watch --uninstall     停用自动复查
  uninstall             彻底卸载（含恢复与停用复查）
  help                  显示本帮助

一键安装（推荐，自动多源回退）：
  curl -sSL https://cdn.jsdelivr.net/gh/dennischancs/mac-block-updates@main/install.sh | bash

  装到本地后用：
  sudo ./update-blocker.sh [命令]

当前系统：macOS $(macos_version)
EOF
}

# ==========================================================================
# 主入口
# ==========================================================================

main() {
    # 记录脚本自身路径（用于自动提权重跑）
    if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
        MUBLOCK_SCRIPT_PATH="${BASH_SOURCE[0]}"
    fi

    local cmd="${1:-}"
    local arg2="${2:-}"

    case "$cmd" in
        ""|menu)
            ensure_root
            gui_menu
            ;;
        block)
            ensure_root
            action_block_all "${arg2:-$DEFAULT_DELAY}"
            ;;
        major-only|majoronly)
            ensure_root
            action_major_only "${arg2:-$DEFAULT_DELAY}"
            ;;
        badge)
            ensure_root
            action_badge
            ;;
        restore)
            ensure_root
            action_restore
            ;;
        status)
            action_status
            ;;
        verify)
            action_verify
            ;;
        watch)
            ensure_root
            case "$arg2" in
                --install|"")   watch_install ;;
                --uninstall)    watch_uninstall ;;
                *)              err "未知参数：$arg2（可用：--install / --uninstall）"; exit 1 ;;
            esac
            ;;
        uninstall)
            ensure_root
            action_uninstall
            ;;
        help|-h|--help)
            show_help
            ;;
        *)
            err "未知命令：$cmd"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
