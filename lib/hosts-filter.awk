#!/usr/bin/awk -f
#
# hosts-filter.awk —— hosts 文件的屏蔽块增删逻辑
#
# 被 update-blocker.sh 与测试套件共用。
# 用法：
#   awk -f hosts-filter.awk -v mode=apply   -v begin=... -v end=... ... < hosts
#   awk -f hosts-filter.awk -v mode=remove -v ...                    < hosts
#
# mode=apply : 删除旧块（含 v1 脚本残留），在 SwitchHosts 标记【之前】插入新块
# mode=remove: 删除所有屏蔽痕迹，其它内容原样保留
#
# 为什么必须放在标记之前：
#   SwitchHosts 以 write_mode=append 托管 /etc/hosts，它的重写逻辑
#   （jt()）只保留 `# --- SWITCHHOSTS_CONTENT_START ---` 之前的内容，
#   标记之后的部分每次刷新都会被丢弃。

function emit_block(    i, d, n2) {
    n2 = split(domains, dd, " ")
    print begin
    for (i = 1; i <= n2; i++) {
        if (dd[i] != "") printf "127.0.0.1\t%s\n", dd[i]
    }
    print end
}

function is_target_domain(    i) {
    for (i = 2; i <= NF; i++) {
        # 注意：必须用 $i（字段值），不能用 i（字段序号）
        if ($i in target) return 1
    }
    return 0
}

BEGIN {
    in_block = 0
    inserted = 0
    n = split(domains, doms, " ")
    for (i = 1; i <= n; i++) {
        if (doms[i] != "") target[doms[i]] = 1
    }
    if (mode == "") mode = "apply"
}

# 我们的块标记
index($0, begin) > 0  { in_block = 1; next }
index($0, end) > 0    { in_block = 0; next }
# 早期 mublock 工具的块标记
index($0, lbegin) > 0 { in_block = 1; next }
index($0, lend) > 0   { in_block = 0; next }
# 块内部的其它行
in_block == 1 { next }

{
    # v1 脚本残留的裸屏蔽条目：整行删除
    if ($1 == "127.0.0.1" || $1 == "0.0.0.0") {
        if (is_target_domain()) next
    }
    # v1 脚本的注释行
    if (index($0, legacy) > 0 && index($0, "#") == 1) next

    # apply 模式：到达 SwitchHosts 标记前插入新块
    if (mode == "apply" && inserted == 0 && index($0, marker) > 0) {
        emit_block()
        print ""
        inserted = 1
    }
    print
}

END {
    # apply 模式且没有 SwitchHosts 标记：追加到文件末尾
    if (mode == "apply" && inserted == 0) {
        print ""
        emit_block()
    }
}
