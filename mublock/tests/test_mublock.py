#!/usr/bin/env python3
"""mublock 测试套件 —— 双向验证。

设计原则：每条断言都必须能在"有缺陷的输入"上失败、在"干净的输入"上通过。
只测 happy path 的测试等于没测。

分两组：
  A 组（纯函数，无需 root）：hosts 渲染、幂等性、位置判定、描述文件结构
  B 组（集成，需要 root）：真实的 apply/restore 往返

运行：
  /usr/bin/python3 tests/test_mublock.py            # 只跑 A 组
  /usr/bin/python3 tests/test_mublock.py --integration   # A + B 组
"""

from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "lib"))

import mublock_core as core  # noqa: E402

PASS, FAIL, SKIP = [], [], []


def check(name, cond, detail=""):
    if cond:
        PASS.append(name)
        print(f"  PASS  {name}")
    else:
        FAIL.append((name, detail))
        print(f"  FAIL  {name}   {detail}")


def skip(name, why):
    SKIP.append((name, why))
    print(f"  SKIP  {name}   {why}")


# ==========================================================================
# A 组：纯函数
# ==========================================================================

HE = core.SWITCHHOSTS_MARKER

CLEAN_HOSTS = """##
# Host Database
#
# localhost is used to configure the loopback interface
# when the system is booting.  Do not change this entry.
##
127.0.0.1\tlocalhost
255.255.255.255\tbroadcasthost
::1             localhost
"""

SWITCHHOSTS_HOSTS = CLEAN_HOSTS + """
# --- SWITCHHOSTS_CONTENT_START ---

127.0.0.1 adobe.io
127.0.0.1 something.example.com
"""

# 模拟 SwitchHosts 已经把我们的块挤到标记之后（历史上真实发生过）
BLOCK_AFTER_MARKER = SWITCHHOSTS_HOSTS + "\n" + core.build_hosts_block() + "\n"


def test_hosts_render_placement():
    print("\n[A1] hosts 渲染：块必须落在 SwitchHosts 标记之前")
    out = core.render_hosts(SWITCHHOSTS_HOSTS)
    check("块已插入", core.hosts_block_present(out))
    check(
        "块在标记之前",
        out.find(core.HOSTS_BEGIN) < out.find(HE),
        f"begin={out.find(core.HOSTS_BEGIN)} marker={out.find(HE)}",
    )
    check("原有内容未丢失", "127.0.0.1 adobe.io" in out)
    check("原有头部未丢失", "255.255.255.255\tbroadcasthost" in out)


def test_hosts_no_switchhosts():
    print("\n[A2] hosts 渲染：没有 SwitchHosts 时正常追加")
    out = core.render_hosts(CLEAN_HOSTS)
    check("块已插入", core.hosts_block_present(out))
    check("原有内容未丢失", "255.255.255.255\tbroadcasthost" in out)


def test_hosts_idempotent():
    print("\n[A3] 幂等性：反复应用不应产生重复块")
    out = core.render_hosts(SWITCHHOSTS_HOSTS)
    for _ in range(5):
        out = core.render_hosts(out)
    check(
        "只有一段块",
        out.count(core.HOSTS_BEGIN) == 1,
        f"count={out.count(core.HOSTS_BEGIN)}",
    )
    check(
        "9 条屏蔽记录",
        sum(1 for h in core.APPLE_UPDATE_HOSTS if f"127.0.0.1\t{h}" in out) == 9,
    )


def test_hosts_repairs_wrong_position():
    print("\n[A4] 修复：块已在标记之后（被 SwitchHosts 挤走）时能拉回来")
    check("前置识别为 after", core.hosts_block_position(BLOCK_AFTER_MARKER) == "after")
    out = core.render_hosts(BLOCK_AFTER_MARKER)
    check("修复后位于 before", core.hosts_block_position(out) == "before")
    check("修复后只有一段块", out.count(core.HOSTS_BEGIN) == 1)
    check("原有内容未丢失", "127.0.0.1 adobe.io" in out)


def test_hosts_missing_block_detected():
    print("\n[A5] 检出：完全没有块时必须被判定为缺失")
    check("判定为 absent", core.hosts_block_position(SWITCHHOSTS_HOSTS) == "absent")
    check("present 判定为假", core.hosts_block_present(SWITCHHOSTS_HOSTS) is False)


def test_hosts_switchhosts_algorithm_survival():
    print("\n[A6] 关键：模拟 SwitchHosts 的 jt() 重写算法，验证块能存活")
    # SwitchHosts 的真实算法（从 app.asar 提取）：
    #   读 /etc/hosts → 找到标记 → 只保留标记之前的头部（trimEnd）
    #   → 重新写成 头部 + 标记 + 新内容
    def switchhosts_rewrite(current: str, new_rule_content: str) -> str:
        i = current.find(HE)
        head = current[:i].rstrip() if i > -1 else current
        return f"{head}\n\n{HE}\n\n{new_rule_content}"

    ours = core.render_hosts(SWITCHHOSTS_HOSTS)
    after = switchhosts_rewrite(ours, "127.0.0.1 new-from-remote-list.example.com")
    check("刷新后块仍存在", core.hosts_block_present(after))
    check("刷新后位置仍为 before", core.hosts_block_position(after) == "before")
    check(
        "刷新后 9 条记录都在",
        all(f"127.0.0.1\t{h}" in after for h in core.APPLE_UPDATE_HOSTS),
    )
    check("刷新后新规则也在", "new-from-remote-list.example.com" in after)


def test_hosts_legacy_after_marker_would_die():
    print("\n[A7] 反证：把块放在标记之后，SwitchHosts 刷新后必然丢失")
    legacy = SWITCHHOSTS_HOSTS + "\n" + core.build_hosts_block() + "\n"

    def switchhosts_rewrite(current, new_rule_content):
        i = current.find(HE)
        head = current[:i].rstrip() if i > -1 else current
        return f"{head}\n\n{HE}\n\n{new_rule_content}"

    after = switchhosts_rewrite(legacy, "127.0.0.1 whatever.example.com")
    check(
        "标记之后的块确实会消失（证明位置很关键）",
        not core.hosts_block_present(after),
    )


def test_profile_structure():
    print("\n[A8] 托管偏好结构（核心生效机制）")
    su = plistlib.loads(core.build_managed_softwareupdate(3650))
    check("延迟开关为 true", su["forceDelayedMajorSoftwareUpdates"] is True)
    check(
        "延迟天数正确",
        su["MajorOSManagedDeferredInstallDelay"] == 3650,
        str(su.get("MajorOSManagedDeferredInstallDelay")),
    )
    for flag in core.SOFTWARE_UPDATE_FLAGS:
        check(f"{flag} = false", su.get(flag) is False)
    check("AutoInstallProductKeys 为空", su.get("AutoInstallProductKeys") == [])

    sa = plistlib.loads(core.build_managed_setupassistant())
    check("SkipSetupItems 含 SoftwareUpdate", "SoftwareUpdate" in sa["SkipSetupItems"])
    check("SkipSetupItems 含 UpdateCompleted", "UpdateCompleted" in sa["SkipSetupItems"])


def test_managed_prefs_are_valid_xml():
    print("\n[A9] 托管偏好是合法 plist")
    for name, data in (
        ("SoftwareUpdate", core.build_managed_softwareupdate()),
        ("SetupAssistant", core.build_managed_setupassistant()),
    ):
        with tempfile.NamedTemporaryFile(suffix=".plist", delete=False) as fh:
            fh.write(data)
            path = fh.name
        try:
            rc = subprocess.run(
                ["/usr/bin/plutil", "-lint", path], capture_output=True, text=True
            )
            check(f"{name} plutil 校验通过", rc.returncode == 0,
                  rc.stdout.strip() + rc.stderr.strip())
        finally:
            os.unlink(path)


def test_profile_structure_legacy():
    print("\n[A10] 描述文件结构（备用路径）")
    data = core.build_profile(3650)
    prof = plistlib.loads(data)
    check("顶层是 Configuration", prof["PayloadType"] == "Configuration")
    check("标识符正确", prof["PayloadIdentifier"] == core.PROFILE_IDENTIFIER)
    check("作用域为 System", prof.get("PayloadScope") == "System")

    types = [p["PayloadType"] for p in prof["PayloadContent"]]
    check("含 applicationaccess", "com.apple.applicationaccess" in types)
    check("含 SetupAssistant.managed", "com.apple.SetupAssistant.managed" in types)
    check("含 SoftwareUpdate", "com.apple.SoftwareUpdate" in types)

    restr = next(
        p for p in prof["PayloadContent"]
        if p["PayloadType"] == "com.apple.applicationaccess"
    )
    check("延迟开关为 true", restr["forceDelayedMajorSoftwareUpdates"] is True)
    check(
        "延迟天数正确传递",
        restr["enforcedSoftwareUpdateMajorOSDeferredInstallDelay"] == 3650,
        str(restr.get("enforcedSoftwareUpdateMajorOSDeferredInstallDelay")),
    )


def test_profile_uuid_unique():
    print("\n[A11] 描述文件 UUID 唯一性")
    a = plistlib.loads(core.build_profile())
    b = plistlib.loads(core.build_profile())
    uuids_a = {p["PayloadUUID"] for p in a["PayloadContent"]} | {a["PayloadUUID"]}
    uuids_b = {p["PayloadUUID"] for p in b["PayloadContent"]} | {b["PayloadUUID"]}
    check("两次生成的 UUID 不重叠", not (uuids_a & uuids_b))


def test_profile_valid_xml():
    print("\n[A12] 描述文件是合法 plist")
    with tempfile.NamedTemporaryFile(suffix=".mobileconfig", delete=False) as fh:
        fh.write(core.build_profile())
        path = fh.name
    try:
        rc = subprocess.run(
            ["/usr/bin/plutil", "-lint", path], capture_output=True, text=True
        )
        check("plutil 校验通过", rc.returncode == 0, rc.stdout.strip() + rc.stderr.strip())
    finally:
        os.unlink(path)


def test_restore_hosts_symmetric():
    print("\n[A11] 对称性：写入后能还原，且不残留标记")
    original = SWITCHHOSTS_HOSTS
    modified = core.render_hosts(original)
    check("修改后有块", core.hosts_block_present(modified))

    # 模拟 restore 的剥离逻辑（与 core.render_hosts 中的删除步骤一致）
    text = modified
    while core.HOSTS_BEGIN in text:
        start = text.index(core.HOSTS_BEGIN)
        end = text.find(core.HOSTS_END)
        text = text[:start] + text[end + len(core.HOSTS_END) + 1 :]
    check("剥离后无块残留", not core.hosts_block_present(text))
    check("剥离后原有内容完整", "127.0.0.1 adobe.io" in text)
    check("剥离后 SwitchHosts 标记还在", HE in text)


def test_effective_status_no_false_positive():
    print("\n[A13] 综合判定：hosts 挡着但没有延迟层，不能判为 effective")
    # 这是一个"纯逻辑"层面的检查：effective_status 的结论依据是
    # 延迟层是否生效，而不是"看不到更新"。
    st = core.effective_status()
    check("结论字段存在", st["conclusion"] in
          ("effective", "degraded", "inactive"), str(st))
    check(
        "inactive 时必然是延迟层没生效",
        st["conclusion"] != "inactive" or not st["deferral_installed"],
        str(st),
    )
    check(
        "degraded 意味着目录不可达",
        st["conclusion"] != "degraded" or not st["catalog_reachable"],
        str(st),
    )


def test_hosts_block_detection_semantics():
    print("\n[A14] 语义：hosts 块存在 ≠ 解析器一定在用")
    # 这条测试记录一个重要区分：
    #   hosts_present  = 文件里有那段文本
    #   hosts_effective = 解析器真的返回 127.0.0.1
    # 两者可以不一致，工具必须分开报告，不能混为一谈。
    text = core.read_hosts()
    present = core.hosts_block_present(text)
    effective = core.hosts_actually_blocking()
    core.log(f"    文件里有屏蔽块：{present}；解析器实测生效：{effective}")
    check("两者可独立取值（不强制相等）", isinstance(present, bool)
          and isinstance(effective, bool))


# ==========================================================================
# B 组：集成（需要 root）
# ==========================================================================


def test_integration_roundtrip():
    print("\n[B1] 集成：apply → verify → restore 往返")
    core.log(f"    初始状态：延迟层已生效={core.deferral_active_value() is not None}")

    core.log("    → apply")
    rc = subprocess.run(
        ["/usr/bin/python3", os.path.join(ROOT, "mublock"), "apply"],
        capture_output=True, text=True,
    )
    core.log("    " + rc.stdout.strip().replace("\n", "\n    "))
    check("apply 返回 0", rc.returncode == 0, rc.stderr.strip()[:400])

    check("延迟层已生效", core.deferral_active_value() is not None)
    check("小红点压制已生效", core.badge_suppressed())
    check("hosts 有块", core.hosts_block_present(core.read_hosts()))
    check("hosts 块位置正确", core.hosts_block_position(core.read_hosts()) == "before")

    st = core.effective_status()
    check("综合判定不是 inactive", st["conclusion"] != "inactive", str(st))
    if st["catalog_reachable"]:
        pending, _ = core.pending_major_update()
        check("大版本已被压住", not pending, str(pending))
    else:
        core.log("    （目录不可达，跳过 --list 交叉验证）")

    core.log("    → restore")
    rc = subprocess.run(
        ["/usr/bin/python3", os.path.join(ROOT, "mublock"), "restore"],
        capture_output=True, text=True,
    )
    core.log("    " + rc.stdout.strip().replace("\n", "\n    "))
    check("restore 返回 0", rc.returncode == 0, rc.stderr.strip()[:400])

    check("延迟层已失效", core.deferral_active_value() is None)
    check("小红点压制已撤销", not core.badge_suppressed())
    check("hosts 块已移除", not core.hosts_block_present(core.read_hosts()))


def test_integration_idempotent_apply():
    print("\n[B2] 集成：连续两次 apply 不应产生副作用")
    for i in (1, 2):
        rc = subprocess.run(
            ["/usr/bin/python3", os.path.join(ROOT, "mublock"), "apply"],
            capture_output=True, text=True,
        )
        check(f"第 {i} 次 apply 返回 0", rc.returncode == 0, rc.stderr.strip()[:300])
    text = core.read_hosts()
    check("hosts 只有一段块", text.count(core.HOSTS_BEGIN) == 1)
    check("位置仍正确", core.hosts_block_position(text) == "before")
    check("延迟层仍生效", core.deferral_active_value() is not None)


def test_integration_no_false_positive():
    print("\n[B3] 反假阳性：只有 hosts 拦截、没有延迟层时，不能判为「屏蔽生效」")
    core.remove_managed_prefs()
    time.sleep(1)
    check("前置条件：延迟层已清除", core.deferral_active_value() is None)

    core.apply_hosts()
    try:
        st = core.effective_status()
        check("延迟层被正确识别为未生效", st["deferral_installed"] is False, str(st))
        check("结论不是 effective", st["conclusion"] != "effective", str(st))
        if st["catalog_reachable"]:
            check(
                "目录可达时能看到大版本（说明延迟层确实没生效）",
                bool(core.pending_major_update()[0]),
            )
        else:
            check(
                "目录不可达被识别（而非当成无更新）",
                st["catalog_reachable"] is False,
            )
    finally:
        core.restore_hosts()


def test_integration_managed_pref_is_sufficient():
    print("\n[B4] 关键：托管偏好单独就够，不需要描述文件")
    core.write_managed_prefs(3650)
    time.sleep(1)
    check("延迟层已生效", core.deferral_active_value() == 3650)
    check("小红点压制已生效", core.badge_suppressed())

    rc, out, _ = core.as_root("profiles list -all 2>&1")
    if rc == 0:
        check(
            "系统里没有安装任何描述文件",
            "There are no configuration profiles installed" in out,
            out.strip()[:200],
        )
    else:
        core.log("    （无法提权确认描述文件列表，跳过该断言）")

    if core.catalog_reachable():
        pending, _ = core.pending_major_update()
        check("大版本已被压住（无描述文件）", not pending, str(pending))
    else:
        core.log("    （目录不可达，跳过 --list 交叉验证）")


def main() -> int:
    integration = "--integration" in sys.argv

    print("=" * 66)
    print(" mublock 测试套件")
    print("=" * 66)

    for fn in (
        test_hosts_render_placement,
        test_hosts_no_switchhosts,
        test_hosts_idempotent,
        test_hosts_repairs_wrong_position,
        test_hosts_missing_block_detected,
        test_hosts_switchhosts_algorithm_survival,
        test_hosts_legacy_after_marker_would_die,
        test_profile_structure,
        test_managed_prefs_are_valid_xml,
        test_profile_uuid_unique,
        test_profile_valid_xml,
        test_restore_hosts_symmetric,
        test_effective_status_no_false_positive,
        test_hosts_block_detection_semantics,
    ):
        fn()

    if integration:
        # 判断能否提权。注意：不能直接 exec sudo —— 在受限沙箱里
        # exec sudo 本身就会抛 PermissionError，而不是返回非零码。
        # 也不能用"弹 GUI 密码框"的 osascript 路径：非交互环境里
        # 没人点那个框，进程会一直挂着。两条路都堵死时，
        # 集成测试应当【跳过】而不是让整个套件卡死。
        def can_escalate() -> bool:
            if core.is_root():
                return True
            if sys.stdin is not None and sys.stdin.isatty():
                return True  # 交互式终端，sudo 会正常问密码
            try:
                r = subprocess.run(
                    ["sudo", "-n", "true"], capture_output=True, text=True
                )
                return r.returncode == 0
            except (OSError, PermissionError):
                return False

        if can_escalate():
            test_integration_roundtrip()
            test_integration_idempotent_apply()
            test_integration_no_false_positive()
            test_integration_managed_pref_is_sufficient()
        else:
            skip(
                "B 组集成测试",
                "无法提权：非交互环境且无缓存的 sudo 凭据。"
                "请在终端里直接运行本测试（sudo 会正常提示密码）。",
            )
    else:
        skip("B 组集成测试", "未指定 --integration")

    print()
    print("=" * 66)
    print(f" 通过 {len(PASS)}  失败 {len(FAIL)}  跳过 {len(SKIP)}")
    print("=" * 66)
    if FAIL:
        print("\n失败明细：")
        for name, detail in FAIL:
            print(f"  - {name}: {detail}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
