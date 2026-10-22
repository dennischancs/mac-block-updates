# mac-block-updates

屏蔽 macOS 大版本升级，留在你现在这个版本。

两个实现，同一套效果：

| 版本 | 入口 | 适合谁 |
|---|---|---|
| **Shell 版** | `update-blocker.sh` | 想要一条命令搞定、不想装任何东西 |
| **Python 版** | `mublock/mublock` | 想看每层状态、用脚本化调用 |

**一键安装（Shell 版）**：

```bash
curl -sSL https://raw.githubusercontent.com/dennischancs/mac-block-updates/main/update-blocker.sh | sudo bash
```

---

## 30 秒上手

```bash
# 屏蔽大版本升级（默认延迟 3650 天 ≈ 10 年）
curl -sSL https://raw.githubusercontent.com/dennischancs/mac-block-updates/main/update-blocker.sh | sudo bash

# 想看状态
sudo bash update-blocker.sh status

# 想恢复
sudo bash update-blocker.sh restore
```

---

## Shell 版

### 两种用法

**管道安装**（临时用，不落盘）：

```bash
curl -sSL https://raw.githubusercontent.com/dennischancs/mac-block-updates/main/update-blocker.sh | sudo bash
```

**下载后运行**（推荐，可反复用、可看源码）：

```bash
curl -sSL -o update-blocker.sh \
  https://raw.githubusercontent.com/dennischancs/mac-block-updates/main/update-blocker.sh
chmod +x update-blocker.sh
sudo ./update-blocker.sh          # 不带参数 = 图形菜单
sudo ./update-blocker.sh block    # 或者直接给命令
```

管道模式跑的是脚本内嵌的 awk 逻辑，功能完全一致。

### 命令

| 命令 | 作用 | 需要 root |
|---|---|---|
| （无参数） | 打开图形菜单选择操作 | 是 |
| `block [天数]` | 屏蔽所有系统更新（默认 3650 天） | 是 |
| `major-only [天数]` | **只屏蔽大版本升级，保留次要/安全更新** | 是 |
| `badge` | 只清除系统设置里的更新小红点 | 是 |
| `restore` | 恢复系统更新 | 是 |
| `status` | 查看当前各层状态 | 否 |
| `verify` | 验证屏蔽是否真的生效 | 否 |
| `watch --install` | 启用每小时自动复查（异常自动修复） | 是 |
| `watch --uninstall` | 停用自动复查 | 是 |
| `uninstall` | 彻底卸载（含恢复与停用复查） | 是 |
| `help` | 显示帮助 | 否 |

### 推荐：`major-only`

只压大版本，次要更新和安全补丁照常收到：

```bash
sudo ./update-blocker.sh major-only
```

---

## Python 版

```bash
git clone https://github.com/dennischancs/mac-block-updates.git
cd mac-block-updates

./mublock/mublock doctor     # 体检：看看这台机器能不能自动装
sudo ./mublock/mublock apply # 上屏蔽
./mublock/mublock verify     # 验证
./mublock/mublock status     # 各层状态
```

| 命令 | 作用 | 需要 root |
|---|---|---|
| `status` | 各层当前状态 + 实际效果 | 否 |
| `doctor` | 环境体检（提权能力、描述文件通道、SwitchHosts、解析器行为） | 否 |
| `apply` | 应用全部屏蔽 | 是 |
| `apply --no-hosts` | 只上托管偏好层（不拦网络，次要/安全更新不受影响） | 是 |
| `restore` | 撤销全部屏蔽 | 是 |
| `verify` | 只看效果不看配置 | 否 |
| `profile generate` | 生成 .mobileconfig（查看用） | 否 |
| `watch --install/--uninstall` | 开关定期复查 | 是 |

Python 版只依赖系统自带的 `/usr/bin/python3`，不需要 pip install。

---

## 它到底做了什么

macOS 升级走三道门，工具三道都能挡：

| 层 | 挡什么 | 机制 |
|---|---|---|
| **托管偏好** | 大版本升级 | `/Library/Managed Preferences/com.apple.SoftwareUpdate.plist` 里写 `forceDelayedMajorSoftwareUpdates` + `MajorOSManagedDeferredInstallDelay` |
| **系统域偏好** | 自动检查/下载/安装 | `/Library/Preferences/com.apple.SoftwareUpdate` |
| **hosts** | 更新服务器网络访问 | 把 9 个更新域名指向 `127.0.0.1` |

小红点单独用 `com.apple.SetupAssistant.managed.plist` 的 `SkipSetupItems` 消掉。

**核心是托管偏好层。** 它是精确的——只压大版本，不影响次要更新。

---

## 几个实测踩过的坑

这些都是在真机上验证过的，写出来免得你也踩：

**1. 描述文件要人工点确认**

macOS 26 移除了 `profiles install`（报 `profiles tool no longer supports installs`）。只剩 `open <file>.mobileconfig` 一条路，而 `open` 只有在**系统里一个配置描述文件都没有**时才免交互装上；只要已存在任何一个，新文件就进「待确认」队列——**跟标识符是否相同无关**。

所以本工具**不依赖描述文件**，直接写托管偏好文件。零 GUI、零确认、一次提权搞定。

**2. hosts 追加到末尾会被抹掉**

如果你在用 SwitchHosts（`write_mode=append`），它每小时重写 `/etc/hosts` 时只保留 `# --- SWITCHHOSTS_CONTENT_START ---` 标记**之前**的头部。追加到末尾的屏蔽条目大约每小时失效一次。

本工具会把屏蔽块放在标记**之前**。

**3. 90 天不是硬上限**

有教程说延迟天数上限是 90 天、需要定期重装。实测填 **3650 天系统照单全收并照常生效**。

**4. 恢复时不能只删文件**

把托管偏好文件删掉**不够**——macOS 的 `softwareupdated` 会保留之前的判定缓存，导致恢复后 `softwareupdate --list` 仍然看不到应有的更新。

必须显式写入「关闭」的值（`forceDelayedMajorSoftwareUpdates=false`），并重启 `cfprefsd` + `softwareupdated`。本工具的 `restore` 已处理。

**5. 恢复后先杀守护进程再看结果**

`softwareupdated` 守护进程有缓存。判断是否恢复成功，要先 `killall -9 softwareupdated` 再跑 `softwareupdate --list`，否则看到的可能是旧状态。

---

## 各版本行为对照

| | Shell 版 `block` | Shell 版 `major-only` | Python 版 `apply` | Python 版 `apply --no-hosts` |
|---|---|---|---|---|
| 压大版本 | ✅ 3650 天 | ✅ 3650 天 | ✅ 3650 天 | ✅ 3650 天 |
| 压次要/安全更新 | ✅ | ❌ 保留 | ✅ | ❌ 保留 |
| 拦 hosts | ✅ | ❌ | ✅ | ❌ |
| 清小红点 | ✅ | ✅ | ✅ | ✅ |
| 自动复查 | 可选 | 可选 | 可选 | 可选 |

**建议**：想要「只挡大版本、次要更新照收」，用 `major-only` 或 `apply --no-hosts`。

---

## 排查

```bash
# 看各层状态
sudo ./update-blocker.sh status

# 实测验证屏蔽是否真的生效
sudo ./update-blocker.sh verify

# 更新目录通不通（hosts 层有没有在拦）
ping -c1 swscan.apple.com
```

`verify` 会区分三种结论，不会把「网络被堵」误判成「屏蔽生效」：

- `effective` — 延迟层生效，目录可达
- `degraded` — 延迟层生效，但目录同时被 hosts 拦了（无法二次交叉验证，**不是故障**）
- `inactive` — 延迟层没生效

---

## 测试

```bash
# Shell 版（A 组：纯逻辑，不需要 root）
./tests/test-update-blocker.sh

# Shell 版（含集成测试，需要 root）
sudo ./tests/test-update-blocker.sh --integration

# Python 版
/usr/bin/python3 mublock/tests/test_mublock.py
sudo /usr/bin/python3 mublock/tests/test_mublock.py --integration
```

---

## 卸载

```bash
sudo ./update-blocker.sh uninstall
```

会恢复所有改动、停用自动复查、清理 hosts 屏蔽块。

---

## License

MIT
