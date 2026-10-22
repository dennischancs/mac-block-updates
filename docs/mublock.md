# mublock — macOS 大版本升级屏蔽工具

> 目标：让这台 Mac 停在当前 macOS 版本，不再被大版本升级（现在是 macOS 27）反复骚扰。
> 做法来自 [eatmoreduck 的博客](https://blog.xiaohuangyu.space/p/block-macos-updates/)，
> 但**本机实测发现博客方案有 4 处关键偏差**，已全部修正 —— 详见下文「与博客的偏差」。

---

## 这台机器当前的实际状态

已应用（`mublock apply` 跑通并逐项验证过）：

| 层 | 状态 | 证据 |
|---|---|---|
| 托管偏好（延迟） | ✅ 生效，3650 天 | `/Library/Managed Preferences/com.apple.SoftwareUpdate.plist` |
| 小红点压制 | ✅ 生效 | `SkipSetupItems=[SoftwareUpdate, UpdateCompleted]` |
| hosts 屏蔽 | ✅ 在位（第 11–21 行）且位于 SwitchHosts 标记（第 23 行）**之前** | 解析实测 `swscan.apple.com → 127.0.0.1` |
| 系统域偏好 | ✅ 5 个开关全关 | `defaults read /Library/Preferences/com.apple.SoftwareUpdate` |

`mublock verify` 的结论是 `degraded`——意思是
**"延迟层已生效，但 hosts 层同时拦住了更新目录，所以没法用 `softwareupdate --list` 二次交叉验证"**。
这不是故障。

### 想让次要/安全更新能正常收到？

hosts 层拦的是整个更新目录，不只是大版本。想只压大版本、保留安全更新：

```bash
/usr/bin/python3 mublock restore --keep-hosts   # 先撤托管偏好
/usr/bin/python3 mublock apply --no-hosts        # 再只上托管偏好
```

（或者直接手动删掉 `/etc/hosts` 里 `# >>> mublock hosts block >>>` 到
`# <<< mublock hosts block <<<` 之间那 11 行，然后 `sudo dscacheutil -flushcache`）

---

## 30 秒上手

```bash
cd mac-block-updates

/usr/bin/python3 mublock doctor     # 先体检：看看这台机器能不能自动装
/usr/bin/python3 mublock apply      # 上屏蔽（会弹一次管理员密码）
/usr/bin/python3 mublock verify     # 验证：macOS 27 是否真的被压住
/usr/bin/python3 mublock status     # 看各层当前状态

# 想恢复更新：
/usr/bin/python3 mublock restore
```

`apply` / `restore` 各自**只弹一次管理员密码框**（所有特权操作合并成一次）。

> **当前这台机器的推荐配置是 `apply --no-hosts`**：
> 托管偏好层是**精确**的——只压大版本升级，次要/安全更新照常能收到；
> hosts 层是**粗暴**的——它把整个更新目录都拦了，连安全更新都收不到。
> 你已经在 26.7.1（2026-10 刚推的），没必要为安全更新冒这个险。
> 想两样都要就跑 `mublock apply`（默认行为）。

---

## 三句话版本

1. **系统真正读的是「托管偏好文件」，不是描述文件。** 直接写
   `/Library/Managed Preferences/com.apple.SoftwareUpdate.plist` 就能压制大版本升级，
   不需要描述文件、不需要 GUI、不需要人工点确认。
2. **本机最大的坑是 SwitchHosts 托管着 `/etc/hosts`**，它每次刷新会重写标记之后的全部内容，
   博客说的"追加到文件末尾"在这台机器上**每小时被抹掉一次**。屏蔽块必须放在
   `# --- SWITCHHOSTS_CONTENT_START ---` 标记**之前**。
3. **你已经在 macOS 26.7.1 上了**——博客要挡的是 macOS 26，但 26 早就装好了。
   现在真正在骚扰你的是 **macOS 27.0.1**（17.9 GB，已上架），本工具挡的是它。

---

## 与博客的偏差（4 处，全部实测）

| # | 博客说法 | 本机实测 | 证据 |
|---|---|---|---|
| 1 | 目标 = 屏蔽 macOS 26 升级 | 本机已是 26.7.1，实际要挡的是 **macOS 27.0.1** | `softwareupdate --list` 显示 27.0.1 / 17.9 GB |
| 2 | 描述文件靠 GUI 装 | macOS 26 **已移除 `profiles install`**（报 "profiles tool no longer supports installs"）。而 `open` 装文件**只有系统里一个描述文件都没有时才免交互**，只要已存在任何一个，新文件就进「待确认」队列需人工点确认 —— **与标识符是否相同无关** | 实测：清空后 `open` 2 秒装上；有残留时 `open` 30 秒不生效 |
| 3 | 90 天是硬上限，要定期重装 | **90 不是本路径的硬约束。**填 3650 天系统照单全收并照常生效 | 托管偏好里原样存了 3650，`softwareupdate --list` 仍为 "No new software available" |
| 4 | hosts 条目追加到文件末尾 | **在有 SwitchHosts 的机器上会被抹掉。**它的 `jt()` 算法只保留标记之前的头部 | 实测：追加后约 1 小时内消失；改成放标记之前后存活 |

> 博客的第四步（用 iMazing / Apple Configurator 手工做 profile）在本机**不必要**：
> 描述文件只是"运输工具"，真正生效的是它落到托管偏好里的那几行键。
> 我们直接写托管偏好，一步到位。`mublock profile generate` 仍可生成 profile 供查看。

---

## 工具怎么工作

### 层 1：托管偏好（核心，唯一必需）

写两个文件（0644 root:wheel）：

`/Library/Managed Preferences/com.apple.SoftwareUpdate.plist`
```xml
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
```

`/Library/Managed Preferences/com.apple.SetupAssistant.managed.plist`
```xml
<dict>
  <key>SkipSetupItems</key>
  <array>
    <string>SoftwareUpdate</string>
    <string>UpdateCompleted</string>
  </array>
</dict>
```

- 前者 = 压制大版本升级 + 关掉自动检查/下载/安装
- 后者 = 消除「系统设置」图标上的更新小红点

**这是独立生效的机制**：实测在系统里**没有装任何描述文件**的情况下，
仅写这两个文件就能让 `softwareupdate --list` 从列出 macOS 27.0.1 变成 "No new software available"。

### 层 2：hosts（纵深防御，可选，`--no-hosts` 可跳过）

把 9 个更新服务器指向 `127.0.0.1`。**必须放在 SwitchHosts 标记之前**：

```
# >>> mublock hosts block >>>
127.0.0.1	swscan.apple.com
...
# <<< mublock hosts block <<<

# --- SWITCHHOSTS_CONTENT_START ---      ← SwitchHosts 从这里开始接管
```

**代价**：它拦的是整个更新目录，不只是大版本 —— 次要/安全更新也会一并收不到。
所以这台机器上的推荐配置是 `apply --no-hosts`：托管偏好层已经足够精确。

### 层 3：定期复查（可选）

`mublock apply --watch` 装一个 launchd 任务，每小时检查一次并自动修复
（托管偏好被删、hosts 块被挤到错误位置等）。

---

## 命令

| 命令 | 作用 | 需要提权 |
|---|---|---|
| `mublock doctor` | 环境体检：提权能力、描述文件通道、SwitchHosts、解析器行为 | 否 |
| `mublock status` | 各层当前状态 + 实际效果 | 否（只读） |
| `mublock apply` | 应用全部屏蔽 | 是（1 次密码） |
| `mublock apply --no-hosts` | 只用托管偏好（保留次要/安全更新） | 是（1 次密码） |
| `mublock apply --watch` | 同上 + 启用每小时自动复查 | 是（1 次密码） |
| `mublock restore` | 撤销全部屏蔽 | 是（1 次密码） |
| `mublock verify` | 只看效果不看配置 | 否 |
| `mublock profile generate` | 生成 .mobileconfig（查看用，不影响生效） | 否 |
| `mublock watch --install/--uninstall` | 开关定期复查 | 是 |

---

## 失败模式（这些是真的会发生）

| 现象 | 原因 | 处理 |
|---|---|---|
| `apply` 报"提权超时" | 系统密码框没人点 | 终端里直接跑，`sudo` 会正常提示 |
| `apply` 说 hosts 屏蔽"未生效" | 解析器还在用 DNS 缓存 | 工具会自动升级到重启 mDNSResponder；仍不行说明 hosts 层不可靠，**但延迟层是独立的，不受影响** |
| 看不到 macOS 27 了，但 `status` 说 hosts 位置错 | SwitchHosts 刷新挪动了内容 | 跑 `mublock apply` 拉回标记之前 |
| `verify` 说"目录不可达" | hosts 层在拦，所以没法交叉验证 | 正常，此时结论是 `degraded`（延迟层生效但无法二次验证） |
| 描述文件装了没生效 | 系统里已有其它描述文件，新文件进了待确认队列 | 「系统设置 → 通用 → 隐私与安全性 → 描述文件」手动点确认 |

---

## 诚实降级说明

- **90 天不是硬上限，但计时起点是 Apple 的发布日期**（不是安装日期）。
  填 3650 天意味着：只要 Apple 不发布新的大版本，这层就一直在。
  Apple 一旦发布 macOS 28，那台的计时会从 28 的发布日重新开始。
  → 所以 `mublock watch` 的定期复查仍然有价值：它能发现新大版本并提醒你。

- **小红点是否真的消失，我只能验证到"托管偏好已写入且能被读取"**这一层
  （`SkipSetupItems` 键存在且值为 `SoftwareUpdate`）。
  红点消失本身需要肉眼看「系统设置」图标 —— 这一步我没法在终端里断言。

- **hosts 层是否真正生效，取决于解析器缓存**，所以工具会**实测解析结果**再下结论，
  不会只看"文件里有没有那几行"就报成功。

- 我在**这台真实机器**上做过完整的 A/B 验证（删掉→macOS 27 回来；写回→消失），
  但**没有在别的 Mac / 别的 macOS 版本上验证过**。

- 我是**一个人**在做这件事，没有第二个人独立审查。
  唯一真正独立的验证是**机械检查**：`softwareupdate --list` 的实际输出、
  `plutil -lint` 的 plist 合法性、测试套件的断言。

---

## 测试

```bash
/usr/bin/python3 tests/test_mublock.py                 # A 组：纯函数，不需要提权
/usr/bin/python3 tests/test_mublock.py --integration   # A + B 组（B 组需要提权）
```

A 组 41 项断言，覆盖：hosts 渲染位置、幂等性、错误位置自动修复、
**模拟 SwitchHosts 重写算法验证块能存活**、托管偏好结构与 plist 合法性、
以及"hosts 挡着但没有延迟层时不能误判为成功"这条反假阳性断言。

B 组 4 组集成测试，真实调用 `apply` / `restore` 做往返，验证：
往返对称、连续 apply 无副作用、反假阳性、以及**"托管偏好单独就够、不需要描述文件"**。

---

## 文件

```
mublock/
├── mublock                     # CLI 入口
├── lib/mublock_core.py         # 核心库（含全部实测结论注释）
├── tests/test_mublock.py       # 测试套件
├── state/                      # 记录改动前原值，供 restore 精确还原
└── mublock.mobileconfig        # （可选）描述文件，仅供查看
```
