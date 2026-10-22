#!/bin/bash
# mac-block-updates 一键安装器
#
# 作用：从多个镜像源依次尝试，下载 update-blocker.sh 并执行。
# 存在的理由：raw.githubusercontent.com 在部分网络环境下连不通，
#             单源 curl 会在第一步就失败。
#
# 用法：
#   curl -sSL <本文件地址> | bash
#   或
#   bash install.sh
#
# 镜像优先级：jsDelivr → GitHub Raw → ghfast 代理
# 全部失败时给出明确提示，不会静默退出。
#
# 关于 CDN 缓存：jsDelivr 按 URL 路径缓存，query 参数绕不过，
# 缓存未刷新时用户会拿到旧版脚本。因此下载后会校验脚本里的
# VERSION 字段，与本安装器的 MIN_VERSION 不一致就换下一个源。
MIN_VERSION="2.0.0"

set -u

SCRIPT_NAME="update-blocker.sh"
REPO="dennischancs/mac-block-updates"
BRANCH="main"

# 候选源：按优先级排列
MIRRORS="
https://cdn.jsdelivr.net/gh/${REPO}@${BRANCH}/${SCRIPT_NAME}
https://raw.githubusercontent.com/${REPO}/${BRANCH}/${SCRIPT_NAME}
https://ghfast.top/https://raw.githubusercontent.com/${REPO}/${BRANCH}/${SCRIPT_NAME}
"

log()  { printf '%s\n' "$*"; }
fail() { printf '%s\n' "$*" >&2; }

# 选一个能用的源
PICKED=""
for url in $MIRRORS; do
    log "[..] 尝试：${url}"
    if curl -fsSL --connect-timeout 8 --max-time 90 "$url" -o /tmp/mac-block-updates.sh 2>/dev/null; then
        # 校验拿到的是不是一个合理的 shell 脚本
        if ! head -1 /tmp/mac-block-updates.sh | grep -qE '^#!.*(ba)?sh'; then
            fail "[!!] 下载内容不像 shell 脚本，换下一个源"
            continue
        fi

        # 校验版本：CDN 缓存未刷新时会给旧版，换下一个源
        GOT=$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' /tmp/mac-block-updates.sh | head -1)
        if [ -n "$GOT" ] && [ "$GOT" != "$MIN_VERSION" ]; then
            fail "[!!] 该源返回的是旧版 (v${GOT}，期望 v${MIN_VERSION})，换下一个源"
            continue
        fi

        PICKED="$url"
        log "[ok] 下载成功（版本 v${GOT:-未知}）"
        break
    else
        fail "[!!] 该源不可达，换下一个源"
    fi
done

if [ -z "$PICKED" ]; then
    fail ""
    fail "所有镜像源都不可达。"
    fail "可以手动下载后运行："
    fail "  git clone https://github.com/${REPO}.git"
    fail "  cd ${REPO} && sudo bash ${SCRIPT_NAME}"
    fail ""
    exit 1
fi

chmod +x /tmp/mac-block-updates.sh 2>/dev/null

# 转交给主脚本。需要 root 的操作会提示输入密码。
exec /bin/bash /tmp/mac-block-updates.sh "$@"
