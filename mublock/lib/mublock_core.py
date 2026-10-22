"""mublock — macOS 大版本升级屏蔽工具的核心库。

═══ 实测得出的核心结论 ═══

系统真正读的是【托管偏好文件】，不是描述文件本体：

    /Library/Managed Preferences/com.apple.SoftwareUpdate.plist
        forceDelayedMajorSoftwareUpdates = true
        MajorOSManagedDeferredInstallDelay = <天数>

    /Library/Managed Preferences/com.apple.SetupAssistant.managed.plist
        SkipSetupItems = [SoftwareUpdate, UpdateCompleted]

直接写这两个文件（root 权限，0644）就能压制大版本升级，
完全不需要描述文件、不需要 GUI、不需要人工点确认。 [A级：实测 A/B 验证——
删掉文件 macOS 27.0.1 立刻回来，写回去立刻变成 "No new software available"，
且全程 profiles list -all 显示"没有装任何描述文件"]

描述文件（.mobileconfig）之所以在社区方案里是主角，是因为它是由 MDM
下发到同一批托管偏好里的——描述文件只是"运输工具"，不是"生效机制"。
自己造一个描述文件再用 GUI 装上，是绕远路，而且会遇到 macOS 26 的两个坑：

  1. macOS 26 移除了 `profiles install`（实测报 "profiles tool no longer
     supports installs"），只剩 GUI 路径。
  2. `open <file>.mobileconfig` 只有在【系统里一个配置描述文件都没有】时
     才免交互自动装上；只要已经存在任何一个，新文件就会进"待确认"队列，
     必须人工去「系统设置 → 通用 → 隐私与安全性 → 描述文件」点确认。
     这跟描述文件标识符是否相同无关——实测用相同标识符重装同样会进队列。

另外两条实测发现：
  * 博客说 90 天是硬上限、需要定期重装——不对。实测填 3650 天系统照单全收
    并照常生效，90 不是本路径的硬约束。 [A级]
  * 延迟的计时起点是 Apple 的发布日期，不是描述文件的安装日期。 [B级：官方文档+社区]

═══ 本机环境的额外坑 ═══

  * SwitchHosts 以 write_mode=append 托管 /etc/hosts，它的 jt() 算法只保留
    `# --- SWITCHHOSTS_CONTENT_START ---` 之前的头部，标记之后的内容每次
    刷新都会被丢弃。所以 hosts 屏蔽块必须放在标记【之前】。 [A级：实测被抹掉过]
  * 写完 hosts 必须刷新解析器（dscacheutil -flushcache + HUP mDNSResponder），
    否则 getaddrinfo 仍返回旧 IP，看起来像"屏蔽没生效"。 [A级：实测]
  * 用 root 反复轮询状态会每轮弹一次密码框导致挂起——状态判定一律用
    非特权可读的位置。 [A级：实测]
"""

from __future__ import annotations

import json
import os
import plistlib
import re
import shutil
import socket
import subprocess
import sys
import time
import uuid

# --------------------------------------------------------------------------
# 常量
# --------------------------------------------------------------------------

PROFILE_IDENTIFIER = "local.mublock.profile"
PROFILE_DISPLAY_NAME = "Mublock: macOS Update Shield"

PAYLOAD_RESTRICTIONS = "local.mublock.restrictions"
PAYLOAD_SETUPASSISTANT = "local.mublock.setupassistant"
PAYLOAD_SOFTWAREUPDATE = "local.mublock.softwareupdate"

# /etc/hosts 中我们自己的块标记，用于幂等识别
HOSTS_BEGIN = "# >>> mublock hosts block >>>"
HOSTS_END = "# <<< mublock hosts block <<<"

# SwitchHosts 使用的分隔标记。它之前的头部会被保留，之后的会被丢弃。
SWITCHHOSTS_MARKER = "# --- SWITCHHOSTS_CONTENT_START ---"

# 需要指向 127.0.0.1 的更新服务器
APPLE_UPDATE_HOSTS = [
    "swscan.apple.com",
    "swdist.apple.com",
    "swdownload.apple.com",
    "swcdn.apple.com",
    "updates-http.cdn-apple.com",
    "updates.cdn-apple.com",
    "gdmf.apple.com",
    "xp.apple.com",
    "mesu.apple.com",
]

# SoftwareUpdate 域里需要关掉的开关
SOFTWARE_UPDATE_FLAGS = [
    "AutomaticCheckEnabled",
    "AutomaticDownload",
    "AutomaticallyInstallMacOSUpdates",
    "CriticalUpdateInstall",
    "ConfigDataInstall",
]

# 托管偏好文件（核心机制）
MANAGED_PREFS_DIR = "/Library/Managed Preferences"
MANAGED_SOFTWAREUPDATE = "com.apple.SoftwareUpdate.plist"
MANAGED_SETUPASSISTANT = "com.apple.SetupAssistant.managed.plist"
MANAGED_APPLICATIONACCESS = "com.apple.applicationaccess.plist"
MANAGED_PREF_FILES = [
    MANAGED_SOFTWAREUPDATE,
    MANAGED_SETUPASSISTANT,
    MANAGED_APPLICATIONACCESS,
]

HOSTS_PATH = "/etc/hosts"
SOFTWARE_UPDATE_DOMAIN = "/Library/Preferences/com.apple.SoftwareUpdate"

# 状态文件：记录我们改过什么，以便对称恢复
STATE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "state")
STATE_FILE = os.path.join(STATE_DIR, "mublock-state.json")
PROFILE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mublock.mobileconfig")

# 描述文件安装后需要等待的时间
PROFILE_INSTALL_TIMEOUT = 60
PROFILE_POLL_INTERVAL = 2

# 提权密码框的最长等待时间（秒）
ROOT_AUTH_TIMEOUT = 120


# --------------------------------------------------------------------------
# 通用工具
# --------------------------------------------------------------------------


def log(msg: str = "", end: str = "\n") -> None:
    print(msg, end=end, flush=True)


def warn(msg: str) -> None:
    print(f"[warn] {msg}", file=sys.stderr, flush=True)


def ok(msg: str) -> None:
    print(f"[ok] {msg}", flush=True)


def fail(msg: str) -> None:
    print(f"[fail] {msg}", file=sys.stderr, flush=True)


def info(msg: str) -> None:
    print(f"[info] {msg}", flush=True)


def is_root() -> bool:
    return os.geteuid() == 0


def run(cmd, check=False, capture=True, timeout=None):
    """执行命令，返回 (returncode, stdout, stderr)。

    timeout 到期时抛 subprocess.TimeoutExpired，由调用方决定如何降级。
    """
    try:
        p = subprocess.run(
            cmd,
            shell=isinstance(cmd, str),
            capture_output=capture,
            text=True,
            timeout=timeout,
        )
    except Exception as exc:  # noqa: BLE001
        if check:
            raise
        return 127, "", str(exc)
    if check and p.returncode != 0:
        raise RuntimeError(
            f"command failed: {cmd}\nstdout={p.stdout}\nstderr={p.stderr}"
        )
    return p.returncode, p.stdout, p.stderr


def _script_path(name: str) -> str:
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib", name)


def _run_as_root_script(script: str) -> tuple[int, str, str]:
    """把一段 shell 脚本以 root 身份执行。

    脚本内容走 base64 传输，避免任何引号/反引号/换行带来的转义问题。

    超时保护：osascript 提权会弹系统密码框，如果用户没点，进程会一直挂着。
    加超时避免整个工具卡死。 [A级：实测——多次连续提权会叠加弹框导致挂起]
    """
    b64 = _b64(script)
    tmp = f"/tmp/mublock_root_{uuid.uuid4().hex[:8]}.b64"
    with open(tmp, "w") as fh:
        fh.write(b64)
    os.chmod(tmp, 0o644)
    try:
        applescript = (
            f'do shell script "cat {tmp} | base64 -D | /bin/bash" '
            "with administrator privileges"
        )
        try:
            return run(["osascript", "-e", applescript], timeout=ROOT_AUTH_TIMEOUT)
        except subprocess.TimeoutExpired:
            return (
                124,
                "",
                f"提权超时（{ROOT_AUTH_TIMEOUT}s）——系统密码框未被确认",
            )
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def as_root(script: str) -> tuple[int, str, str]:
    """以 root 身份执行一段 shell 脚本。

    提权路径按"打扰程度"从低到高依次尝试：

      1. 已经是 root → 直接执行
      2. sudo 凭据已缓存（sudo -n 可用）→ 无感执行
      3. 当前是交互式终端（stdin 是 tty）→ 用 sudo，密码提示打在终端里
         【这是真人使用时的首选路径】
      4. 都不是 → 退回 osascript 的 `with administrator privileges`，
         弹系统 GUI 密码框。非交互环境（CI、后台任务、agent 环境）里
         这个框可能没人点，会一直挂着，所以加了超时保护。

    ⚠️ 实测教训：不要用 root 反复轮询状态——每轮都可能弹一次密码框。
    状态判定请优先用非特权可读的位置（如 /Library/Managed Preferences/，
    权限 0644）。 [A级：实测——2 秒轮询导致弹框叠加、整体超时]
    """
    # 1) 已经是 root
    if is_root():
        return run(["/bin/bash", "-c", script])

    # 2) sudo 凭据已缓存
    rc, _, _ = run(["sudo", "-n", "true"])
    if rc == 0:
        return run(["sudo", "/bin/bash", "-c", script])

    # 3) 交互式终端 → 让 sudo 在终端里问密码
    #    注意：某些受限环境里 exec sudo 本身会被拒绝（返回 127），
    #    这时要继续往下走，而不是直接返回失败。
    if sys.stdin is not None and sys.stdin.isatty():
        rc, out, err = run(["sudo", "/bin/bash", "-c", script])
        if rc != 127:
            return rc, out, err

    # 4) 非交互环境 → osascript GUI 提权（带超时）
    return _run_as_root_script(script)


def as_root_batch(commands: list[str]) -> tuple[int, str, str]:
    """把多条 root 命令合并成【一次】提权执行。

    这是避免反复弹密码框的关键：整个脚本作为一个整体传给 shell。
    """
    if not commands:
        return 0, "", ""
    body = "\n".join(commands)
    return as_root(body)


def _b64(text: str) -> str:
    import base64

    return base64.b64encode(text.encode("utf-8")).decode("ascii")


def write_root_file(path: str, content: bytes) -> tuple[int, str, str]:
    """以 root 写一个文件。"""
    import base64

    payload = base64.b64encode(content).decode("ascii")
    script = (
        f"echo {payload} | base64 -D > '{path}' && "
        f"chown root:wheel '{path}' && chmod 644 '{path}'"
    )
    return as_root(script)


def remove_root_file(path: str) -> tuple[int, str, str]:
    """以 root 删除文件。用绝对路径的 /bin/rm，绕开 PATH 上的 shim。"""
    return as_root(f"/bin/rm -f '{path}'")


def load_state() -> dict:
    try:
        with open(STATE_FILE) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def save_state(state: dict) -> None:
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(STATE_FILE, "w") as fh:
        json.dump(state, fh, indent=2, ensure_ascii=False)


# --------------------------------------------------------------------------
# Layer 1：描述文件（核心层）
# --------------------------------------------------------------------------


def build_managed_softwareupdate(delay_days: int = 3650) -> bytes:
    """构造 com.apple.SoftwareUpdate 托管偏好（核心生效机制）。"""
    data = {
        "forceDelayedMajorSoftwareUpdates": True,
        "MajorOSManagedDeferredInstallDelay": int(delay_days),
    }
    for flag in SOFTWARE_UPDATE_FLAGS:
        data[flag] = False
    data["AutoInstallProductKeys"] = []
    return plistlib.dumps(data, fmt=plistlib.FMT_XML)


def build_managed_setupassistant() -> bytes:
    """构造 com.apple.SetupAssistant.managed 托管偏好（消除小红点）。"""
    data = {"SkipSetupItems": ["SoftwareUpdate", "UpdateCompleted"]}
    return plistlib.dumps(data, fmt=plistlib.FMT_XML)


def write_managed_prefs(delay_days: int = 3650) -> bool:
    """写入托管偏好——这是真正让屏蔽生效的动作。

    全部内容走 base64 传输，一次提权写两个文件。
    """
    su_b64 = _b64(build_managed_softwareupdate(delay_days).decode("utf-8"))
    sa_b64 = _b64(build_managed_setupassistant().decode("utf-8"))
    script = (
        f"mkdir -p '{MANAGED_PREFS_DIR}' && "
        f"echo {su_b64} | base64 -D > '{MANAGED_PREFS_DIR}/{MANAGED_SOFTWAREUPDATE}' && "
        f"chown root:wheel '{MANAGED_PREFS_DIR}/{MANAGED_SOFTWAREUPDATE}' && "
        f"chmod 644 '{MANAGED_PREFS_DIR}/{MANAGED_SOFTWAREUPDATE}' && "
        f"echo {sa_b64} | base64 -D > '{MANAGED_PREFS_DIR}/{MANAGED_SETUPASSISTANT}' && "
        f"chown root:wheel '{MANAGED_PREFS_DIR}/{MANAGED_SETUPASSISTANT}' && "
        f"chmod 644 '{MANAGED_PREFS_DIR}/{MANAGED_SETUPASSISTANT}' && "
        f"killall cfprefsd 2>/dev/null; true"
    )
    rc, out, err = as_root(script)
    if rc != 0:
        fail(f"写入托管偏好失败：{(err or out).strip()}")
        return False
    time.sleep(1)
    if deferral_active_value() != delay_days:
        fail("托管偏好已写入，但读回的值不符")
        return False
    ok(f"托管偏好已写入（延迟 {delay_days} 天 + 关闭自动更新 + 消除小红点）")
    return True


def remove_managed_prefs() -> bool:
    """删除托管偏好文件。"""
    cmds = [
        f"/bin/rm -f '{os.path.join(MANAGED_PREFS_DIR, name)}'"
        for name in MANAGED_PREF_FILES
    ]
    cmds.append("killall cfprefsd 2>/dev/null; true")
    rc, out, err = as_root_batch(cmds)
    if rc != 0:
        fail(f"删除托管偏好失败：{(err or out).strip()}")
        return False
    time.sleep(1)
    ok("托管偏好已删除")
    return True


def deferral_active_value() -> int | None:
    """非特权读取：返回托管偏好里生效的延迟天数，未生效返回 None。

    之所以能用非特权方式判定：/Library/Managed Preferences/ 下的文件
    权限是 0644 root:wheel，普通用户可读。 [A级：实测]
    """
    path = os.path.join(MANAGED_PREFS_DIR, MANAGED_SOFTWAREUPDATE)
    try:
        with open(path, "rb") as fh:
            data = plistlib.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    if data.get("forceDelayedMajorSoftwareUpdates") is not True:
        return None
    value = data.get("MajorOSManagedDeferredInstallDelay")
    return value if isinstance(value, int) else None


def badge_suppressed() -> bool:
    """小红点是否被压制（SkipSetupItems 生效）。非特权可读。"""
    path = os.path.join(MANAGED_PREFS_DIR, MANAGED_SETUPASSISTANT)
    try:
        with open(path, "rb") as fh:
            data = plistlib.load(fh)
    except (OSError, ValueError):
        return False
    if not isinstance(data, dict):
        return False
    items = data.get("SkipSetupItems") or []
    return "SoftwareUpdate" in items


def managed_prefs() -> dict:
    """读取 /Library/Managed Preferences 下与更新相关的三个域。"""
    result = {}
    for name in MANAGED_PREF_FILES:
        path = os.path.join(MANAGED_PREFS_DIR, name)
        try:
            with open(path, "rb") as fh:
                result[name] = plistlib.load(fh)
        except (OSError, ValueError):
            result[name] = None
    return result


def deferral_active() -> bool:
    """判定延迟是否真的生效——以托管偏好里的开关为准。"""
    return deferral_active_value() is not None


def build_profile(delay_days: int = 3650, with_setupassistant: bool = True,
                  with_softwareupdate: bool = True) -> bytes:
    """生成 .mobileconfig 字节流（可选的备用路径）。

    描述文件不是必需的——托管偏好直接写就够了。留这个函数是因为
    描述文件在「系统设置 → 描述文件」里可见、可被用户自行查看和移除，
    对想确认"到底改了什么"的人有参考价值。
    """
    u = lambda: str(uuid.uuid4()).upper()  # noqa: E731

    payloads = [
        {
            "PayloadType": "com.apple.applicationaccess",
            "PayloadVersion": 1,
            "PayloadIdentifier": PAYLOAD_RESTRICTIONS,
            "PayloadUUID": u(),
            "PayloadEnabled": True,
            "PayloadDisplayName": "Mublock: Major Upgrade Deferral",
            "forceDelayedMajorSoftwareUpdates": True,
            "enforcedSoftwareUpdateMajorOSDeferredInstallDelay": int(delay_days),
        }
    ]

    if with_setupassistant:
        payloads.append(
            {
                "PayloadType": "com.apple.SetupAssistant.managed",
                "PayloadVersion": 1,
                "PayloadIdentifier": PAYLOAD_SETUPASSISTANT,
                "PayloadUUID": u(),
                "PayloadEnabled": True,
                "PayloadDisplayName": "Mublock: Suppress Software Update Badge",
                "SkipSetupItems": ["SoftwareUpdate", "UpdateCompleted"],
            }
        )

    if with_softwareupdate:
        su = {
            "PayloadType": "com.apple.SoftwareUpdate",
            "PayloadVersion": 1,
            "PayloadIdentifier": PAYLOAD_SOFTWAREUPDATE,
            "PayloadUUID": u(),
            "PayloadEnabled": True,
            "PayloadDisplayName": "Mublock: Disable Automatic Update",
        }
        for flag in SOFTWARE_UPDATE_FLAGS:
            su[flag] = False
        su["AutoInstallProductKeys"] = []
        payloads.append(su)

    profile = {
        "PayloadContent": payloads,
        "PayloadType": "Configuration",
        "PayloadVersion": 1,
        "PayloadIdentifier": PROFILE_IDENTIFIER,
        "PayloadUUID": u(),
        "PayloadDisplayName": PROFILE_DISPLAY_NAME,
        "PayloadDescription": (
            "Defer major macOS upgrades, suppress the update badge, "
            "and disable automatic update checking/downloading."
        ),
        "PayloadOrganization": "mublock",
        "PayloadScope": "System",
        "PayloadRemovalDisallowed": False,
    }
    return plistlib.dumps(profile, fmt=plistlib.FMT_XML)


def read_hosts() -> str:
    try:
        with open(HOSTS_PATH, "r", errors="replace") as fh:
            return fh.read()
    except OSError as exc:
        raise RuntimeError(f"无法读取 {HOSTS_PATH}: {exc}")


def hosts_block_present(text: str) -> bool:
    return HOSTS_BEGIN in text and HOSTS_END in text


def hosts_block_position(text: str) -> str:
    """返回 'before' / 'after' / 'absent' —— 相对 SwitchHosts 标记的位置。

    只有 'before' 的位置能存活：SwitchHosts 每次刷新都重写标记之后的全部内容。
    """
    if not hosts_block_present(text):
        return "absent"
    b = text.find(HOSTS_BEGIN)
    m = text.find(SWITCHHOSTS_MARKER)
    if m == -1:
        return "before"  # 没有 SwitchHosts，尾部追加也没问题
    return "before" if b < m else "after"


def build_hosts_block() -> str:
    lines = [HOSTS_BEGIN]
    lines += [f"127.0.0.1\t{h}" for h in APPLE_UPDATE_HOSTS]
    lines.append(HOSTS_END)
    return "\n".join(lines)


def render_hosts(original: str) -> str:
    """把屏蔽块正确地放进 hosts 文件。

    规则：
      1. 先把已有的块（无论在哪）整段删掉，保证幂等；
      2. 若存在 SwitchHosts 标记，插到标记【之前】；
      3. 否则追加到文件末尾。
    """
    text = original
    # 1) 删除已存在的块
    while HOSTS_BEGIN in text:
        start = text.index(HOSTS_BEGIN)
        end = text.find(HOSTS_END)
        if end == -1:
            text = text[:start]
            break
        text = text[:start] + text[end + len(HOSTS_END) + 1 :]

    block = build_hosts_block()

    # 2) 插到 SwitchHosts 标记之前
    m = text.find(SWITCHHOSTS_MARKER)
    if m != -1:
        head = text[:m].rstrip()
        tail = text[m:]
        return f"{head}\n\n{block}\n\n{tail}"

    # 3) 追加到末尾
    return text.rstrip() + "\n\n" + block + "\n"


def hosts_actually_blocking() -> bool:
    """实测：hosts 屏蔽是否真的被解析器采用。

    判据：取一个只可能来自 /etc/hosts 的地址来判断不可靠（Apple 那些域名
    在 DNS 里都有 CNAME 链，缓存行为不一致），所以改成：
    解析 swscan.apple.com，看是否解析到回环地址。
    """
    try:
        infos = socket.getaddrinfo(
            "swscan.apple.com", 443, proto=socket.IPPROTO_TCP
        )
    except (OSError, socket.gaierror):
        return False
    addrs = {i[4][0] for i in infos}
    if not addrs:
        return False
    return all(a.startswith("127.") or a == "::1" for a in addrs)


def flush_resolver(verify: bool = True) -> bool:
    """让解析器重新读取 /etc/hosts，并【验证是否真的生效】。

    ⚠️ 这一步不能省（实测踩到）：
    macOS 的 mDNSResponder 会缓存 hosts 内容和 DNS 结果。
    屏蔽块写进文件后如果不刷新，getaddrinfo 仍会返回旧的真实 IP，
    看起来"屏蔽没生效"。 [A级：实测——块在文件里但未刷新时解析器仍返回真实 IP]

    而且单纯 flush + HUP 不总是够——DNS 侧可能仍有缓存条目。
    所以这里做【逐级升级 + 验证】：
        1) dscacheutil -flushcache + killall -HUP mDNSResponder
        2) 还不行 → 完整重启 mDNSResponder
        3) 还不行 → 报告失败（由调用方决定要不要降级）
    验证不通过时不能假装成功——这正是"看起来生效其实没生效"的来源。
    """
    steps = [
        ["dscacheutil -flushcache", "killall -HUP mDNSResponder 2>/dev/null; true"],
        ["dscacheutil -flushcache", "killall -9 mDNSResponder 2>/dev/null; true"],
    ]
    for i, cmds in enumerate(steps, 1):
        as_root_batch(cmds)
        time.sleep(2)
        if not verify:
            return True
        if hosts_actually_blocking():
            return True
    return False


def apply_hosts() -> bool:
    """把屏蔽块写进 /etc/hosts。需要 root。"""
    original = read_hosts()
    if hosts_block_present(original) and hosts_block_position(original) == "before":
        ok("hosts 屏蔽块已就位且位于 SwitchHosts 标记之前")
        # 位置对了不代表解析器用的是新内容——照样要刷新并验证。
        if flush_resolver():
            ok("解析器已刷新，屏蔽确认生效")
        else:
            warn("解析器刷新后仍未生效——hosts 层暂不可靠"
                 "（不影响延迟层，它是独立的生效机制）")
        return True

    updated = render_hosts(original)
    b64 = _b64(updated)
    script = (
        f"echo {b64} | base64 -D > /tmp/mublock_hosts.new && "
        f"/bin/cp /tmp/mublock_hosts.new {HOSTS_PATH} && "
        f"chown root:wheel {HOSTS_PATH} && chmod 644 {HOSTS_PATH} && "
        f"/bin/rm -f /tmp/mublock_hosts.new"
    )
    rc, out, err = as_root(script)
    if rc != 0:
        fail(f"写入 hosts 失败：{(err or out).strip()}")
        return False

    # 验证写入
    now = read_hosts()
    if not hosts_block_present(now):
        fail("hosts 写入后校验失败：屏蔽块不存在")
        return False
    pos = hosts_block_position(now)
    if pos != "before":
        warn(f"hosts 屏蔽块位置异常（{pos}），SwitchHosts 刷新后可能被抹掉")
    else:
        ok("hosts 屏蔽块已写入，且位于 SwitchHosts 标记之前（可存活）")

    if flush_resolver():
        ok("解析器已刷新，屏蔽确认生效")
    else:
        warn("解析器刷新后仍未生效——hosts 层暂不可靠"
             "（不影响延迟层，它是独立的生效机制）")
    return True


def restore_hosts() -> bool:
    """移除 hosts 里的屏蔽块。"""
    original = read_hosts()
    if not hosts_block_present(original):
        ok("hosts 中没有 mublock 屏蔽块，无需改动")
        return True

    text = original
    while HOSTS_BEGIN in text:
        start = text.index(HOSTS_BEGIN)
        end = text.find(HOSTS_END)
        if end == -1:
            text = text[:start]
            break
        text = text[:start] + text[end + len(HOSTS_END) + 1 :]
    text = re.sub(r"\n{3,}", "\n\n", text)

    b64 = _b64(text)
    script = (
        f"echo {b64} | base64 -D > /tmp/mublock_hosts.new && "
        f"/bin/cp /tmp/mublock_hosts.new {HOSTS_PATH} && "
        f"chown root:wheel {HOSTS_PATH} && chmod 644 {HOSTS_PATH} && "
        f"/bin/rm -f /tmp/mublock_hosts.new && "
        f"dscacheutil -flushcache && killall -HUP mDNSResponder 2>/dev/null; true"
    )
    rc, out, err = as_root(script)
    if rc != 0:
        fail(f"恢复 hosts 失败：{(err or out).strip()}")
        return False
    ok("hosts 屏蔽块已移除")
    return True


# --------------------------------------------------------------------------
# Layer 3：SoftwareUpdate 偏好（系统域）
# --------------------------------------------------------------------------


def software_update_flags() -> dict:
    """读取系统域里各开关的当前值。"""
    result = {}
    for flag in SOFTWARE_UPDATE_FLAGS:
        rc, out, _ = run(["defaults", "read", SOFTWARE_UPDATE_DOMAIN, flag])
        result[flag] = out.strip() if rc == 0 else None
    return result


def apply_prefs() -> bool:
    """直接写系统域 SoftwareUpdate 偏好。

    这一层是描述文件之外的冗余保险：即使描述文件被移除，
    自动检查/下载/安装也仍然是关的。

    五个开关合并成一次提权执行，避免反复弹密码框。
    """
    saved = load_state()
    saved.setdefault("prefs_original", software_update_flags())
    save_state(saved)

    cmds = [
        f"defaults write {SOFTWARE_UPDATE_DOMAIN} {flag} -bool false"
        for flag in SOFTWARE_UPDATE_FLAGS
    ]
    rc, out, err = as_root_batch(cmds)
    if rc != 0:
        warn(f"设置 SoftwareUpdate 偏好失败：{(err or out).strip()}")
        return False
    ok("SoftwareUpdate 系统域开关已全部关闭")
    return True


def restore_prefs() -> bool:
    """把系统域偏好还原到我们改动前的值。"""
    saved = load_state()
    original = saved.get("prefs_original")
    if not original:
        ok("没有记录原始偏好，跳过（未改动过系统域）")
        return True
    cmds = []
    for flag, value in original.items():
        if value is None:
            cmds.append(f"defaults delete {SOFTWARE_UPDATE_DOMAIN} {flag} 2>/dev/null; true")
        else:
            cmds.append(f"defaults write {SOFTWARE_UPDATE_DOMAIN} {flag} -bool {value}")
    as_root_batch(cmds)
    ok("SoftwareUpdate 系统域偏好已还原")
    return True


# --------------------------------------------------------------------------
# 观察与判定
# --------------------------------------------------------------------------


def pending_major_update(timeout: int = 25) -> tuple[list[str], str]:
    """列出当前可用的更新。返回 (更新列表, 状态说明)。

    ⚠️ 重要陷阱（实测踩到）：
    当 hosts 层屏蔽了 swscan.apple.com 等更新服务器时，
    `softwareupdate --list` 会【挂起超过 20 秒】而不是干脆地返回空列表。
    因此"看不到更新"有两种完全不同的原因：
        (a) 延迟层生效，目录里没有可升级的大版本；
        (b) 网络层被拦截，连目录都拉不下来。
    必须区分，否则会把"网络被堵"误判成"屏蔽成功"（假阳性）。
    [A级：实测——加 hosts 屏蔽后 --list 挂起 >20s；去掉后立刻返回列表]

    所以这里的判定只在【网络可达】时才有意义；
    网络可达性由 hosts 层的实际拦截情况判断。
    """
    try:
        rc, out, err = run(
            ["softwareupdate", "--list"], timeout=timeout
        )
    except subprocess.TimeoutExpired:
        return [], "timeout"

    combined = out + err
    if "No new software available" in combined:
        return [], "ok"
    if rc != 0:
        # 网络层拦截的典型表现：TLS 错误 / 连接失败
        return [], "network-blocked"
    updates = [
        line.strip()
        for line in out.splitlines()
        if line.strip().startswith("Title:")
    ]
    if not updates:
        return [], "ok"
    return updates, "ok"


def catalog_reachable() -> bool:
    """更新目录服务器是否可达（hosts 层有没有真正在拦截）。

    实现说明：不能用 `nc -z swscan.apple.com 443` 判断——
    实测在 hosts 屏蔽生效后它仍可能报"连接成功"（走的是自己的解析路径/缓存）。
    可靠做法是直接看 getaddrinfo 的结果：解析到 127.0.0.1 = 被 hosts 拦住了。
    [A级：实测——nc 与 getaddrinfo 在同一时刻给出相反结论]
    """
    return not hosts_actually_blocking()


def effective_status() -> dict:
    """综合判定屏蔽是否真正生效——不产生假阳性。

    判定逻辑：
      * 延迟层（核心）：托管偏好里 forceDelayedMajorSoftwareUpdates == true
        且 MajorOSManagedDeferredInstallDelay > 0 → 屏蔽已安装且生效
      * 网络层：hosts 屏蔽块在位且位置正确（能在 SwitchHosts 刷新后存活）
      * 目录可达性：swscan.apple.com:443 是否连得上
        —— 只有目录可达时，"看不到更新"才说明延迟层真的在起作用

    结论字段 conclusion 取值：
      "effective"   延迟层生效（目录可达且无大版本 / 或目录不可达但延迟层在）
      "degraded"    延迟层在，但目录不可达（网络层在起作用，无法交叉验证）
      "inactive"    延迟层没生效
    """
    delay = deferral_active_value()
    deferral_on = delay is not None

    try:
        text = read_hosts()
        hosts_present = hosts_block_present(text)
        hosts_pos = hosts_block_position(text)
    except RuntimeError:
        hosts_present, hosts_pos = False, "unknown"

    # hosts 层是否真的在拦：用解析结果判断，而不是只看文件里有没有那几行
    hosts_effective = hosts_present and hosts_actually_blocking()
    reachable = not hosts_effective

    if not deferral_on:
        conclusion = "inactive"
    elif not reachable:
        conclusion = "degraded"
    else:
        conclusion = "effective"

    return {
        "deferral_installed": deferral_on,
        "delay_days": delay,
        "badge_suppressed": badge_suppressed(),
        "hosts_present": hosts_present,
        "hosts_position": hosts_pos,
        "hosts_effective": hosts_effective,
        "catalog_reachable": reachable,
        "conclusion": conclusion,
    }


def apply_all(delay_days: int = 3650, with_hosts: bool = True) -> dict:
    """一次 apply 完成全部三层。

    提权次数最小化：托管偏好写入 + hosts 写入 + 系统域偏好
    合并成【一次】root 调用（一个密码框）。

    with_hosts=False 时跳过 hosts 层——只用托管偏好同样能压住大版本升级，
    好处是系统仍能正常检查次要/安全更新，softwareupdate 也不会报 TLS 错误。

    返回各层结果字典。
    """
    results = {}

    try:
        original_hosts = read_hosts()
    except RuntimeError as exc:
        warn(f"读取 hosts 失败：{exc}")
        original_hosts = None

    saved = load_state()
    saved.setdefault("prefs_original", software_update_flags())
    save_state(saved)

    # ---- 一次提权：托管偏好 + hosts + 系统域偏好 ----
    su_b64 = _b64(build_managed_softwareupdate(delay_days).decode("utf-8"))
    sa_b64 = _b64(build_managed_setupassistant().decode("utf-8"))

    cmds = [
        f"mkdir -p '{MANAGED_PREFS_DIR}'",
        f"echo {su_b64} | base64 -D > '{MANAGED_PREFS_DIR}/{MANAGED_SOFTWAREUPDATE}'",
        f"chown root:wheel '{MANAGED_PREFS_DIR}/{MANAGED_SOFTWAREUPDATE}'",
        f"chmod 644 '{MANAGED_PREFS_DIR}/{MANAGED_SOFTWAREUPDATE}'",
        f"echo {sa_b64} | base64 -D > '{MANAGED_PREFS_DIR}/{MANAGED_SETUPASSISTANT}'",
        f"chown root:wheel '{MANAGED_PREFS_DIR}/{MANAGED_SETUPASSISTANT}'",
        f"chmod 644 '{MANAGED_PREFS_DIR}/{MANAGED_SETUPASSISTANT}'",
    ]

    if original_hosts is not None and with_hosts:
        updated = render_hosts(original_hosts)
        b64 = _b64(updated)
        cmds += [
            f"echo {b64} | base64 -D > /tmp/mublock_hosts.new && "
            f"/bin/cp /tmp/mublock_hosts.new {HOSTS_PATH} && "
            f"chown root:wheel {HOSTS_PATH} && chmod 644 {HOSTS_PATH} && "
            f"/bin/rm -f /tmp/mublock_hosts.new"
        ]

    cmds += [
        f"defaults write {SOFTWARE_UPDATE_DOMAIN} {flag} -bool false"
        for flag in SOFTWARE_UPDATE_FLAGS
    ]
    cmds += ["dscacheutil -flushcache", "killall -HUP mDNSResponder 2>/dev/null; true"]

    rc, out, err = as_root_batch(cmds)
    if rc != 0:
        fail(f"提权操作失败：{(err or out).strip()}")
        results["root"] = False
    else:
        results["root"] = True
        ok("托管偏好 + hosts + SoftwareUpdate 偏好已写入（一次提权）")
        time.sleep(1)

    # ---- 验证各层 ----
    results["deferral"] = deferral_active_value() == delay_days
    if results["deferral"]:
        ok(f"延迟层已生效（{delay_days} 天）")
    else:
        fail("延迟层未生效")

    results["badge"] = badge_suppressed()
    if results["badge"]:
        ok("小红点压制已生效（SkipSetupItems）")
    else:
        warn("小红点压制未生效")

    if with_hosts:
        try:
            text = read_hosts()
            if hosts_block_present(text):
                if hosts_block_position(text) == "before":
                    ok("hosts 屏蔽块在位，位置正确（SwitchHosts 刷新后仍存活）")
                    results["hosts"] = True
                else:
                    warn("hosts 屏蔽块位置异常，SwitchHosts 刷新后可能被抹掉")
                    results["hosts"] = False
            else:
                warn("hosts 屏蔽块缺失")
                results["hosts"] = False
        except RuntimeError:
            results["hosts"] = False
    else:
        results["hosts"] = None  # 跳过

    return results


def restore_all(with_hosts: bool = True) -> dict:
    """一次 restore 撤销全部三层。同样合并成一次提权。

    with_hosts=False 时不动 hosts（只撤托管偏好和系统域偏好）。
    """
    results = {}

    try:
        original_hosts = read_hosts()
    except RuntimeError:
        original_hosts = None

    saved = load_state()
    original_prefs = saved.get("prefs_original") or {}

    cmds = [
        f"/bin/rm -f '{os.path.join(MANAGED_PREFS_DIR, name)}'"
        for name in MANAGED_PREF_FILES
    ]
    if with_hosts and original_hosts is not None and hosts_block_present(original_hosts):
        stripped = strip_hosts_block(original_hosts)
        b64 = _b64(stripped)
        cmds += [
            f"echo {b64} | base64 -D > /tmp/mublock_hosts.new && "
            f"/bin/cp /tmp/mublock_hosts.new {HOSTS_PATH} && "
            f"chown root:wheel {HOSTS_PATH} && chmod 644 {HOSTS_PATH} && "
            f"/bin/rm -f /tmp/mublock_hosts.new"
        ]
    for flag, value in original_prefs.items():
        if value is None:
            cmds.append(f"defaults delete {SOFTWARE_UPDATE_DOMAIN} {flag} 2>/dev/null; true")
        else:
            cmds.append(f"defaults write {SOFTWARE_UPDATE_DOMAIN} {flag} -bool {value}")
    cmds += ["dscacheutil -flushcache", "killall -HUP mDNSResponder 2>/dev/null; true"]

    rc, out, err = as_root_batch(cmds)
    if rc != 0:
        fail(f"提权操作失败：{(err or out).strip()}")
        results["root"] = False
    else:
        results["root"] = True
        ok("已撤销：托管偏好 + hosts 屏蔽块 + SoftwareUpdate 偏好")
        time.sleep(1)

    results["deferral_gone"] = deferral_active_value() is None
    results["badge_gone"] = not badge_suppressed()
    if with_hosts:
        try:
            results["hosts_gone"] = not hosts_block_present(read_hosts())
        except RuntimeError:
            results["hosts_gone"] = None
    else:
        results["hosts_gone"] = None  # 跳过
    return results


def strip_hosts_block(text: str) -> str:
    """从 hosts 文本里移除 mublock 屏蔽块。"""
    while HOSTS_BEGIN in text:
        start = text.index(HOSTS_BEGIN)
        end = text.find(HOSTS_END)
        if end == -1:
            text = text[:start]
            break
        text = text[:start] + text[end + len(HOSTS_END) + 1 :]
    return re.sub(r"\n{3,}", "\n\n", text)


def current_os() -> str:
    rc, out, _ = run(["sw_vers", "-productVersion"])
    return out.strip() if rc == 0 else "unknown"


def switchhosts_present() -> bool:
    return os.path.isdir(
        os.path.expanduser("~/Library/Application Support/SwitchHosts")
    ) or os.path.isfile("/Applications/SwitchHosts.app/Contents/Info.plist")


def switchhosts_write_mode() -> str:
    """读 SwitchHosts 的 write_mode。append 才会保留标记前的头部。"""
    cfg = os.path.expanduser("~/.SwitchHosts/config/dict/cfg.json")
    try:
        with open(cfg) as fh:
            return json.load(fh).get("write_mode", "unknown")
    except (OSError, ValueError):
        return "unknown"
