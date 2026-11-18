# QuotaPin

在 macOS 菜单栏上同时显示多个 **Claude** 和 **Codex（ChatGPT）** 订阅的剩余额度，并告诉你现在该先用哪个账号，尽量在每周额度清零前把每个账号都用完。

*A tiny macOS menu bar app that shows usage limits for multiple Claude and Codex subscriptions, and recommends which account to use next so no weekly quota goes to waste.*

```
▸C1 62%!  C2 8%  X 8%
```

- `▸` 推荐现在先用的账号
- `!` 该账号有某个模型的专属额度（例如 Fable）超过 90%
- 数字是 5 小时额度和每周额度里较高的那个；超过 70% 变橙色，超过 90% 变红色

点开菜单可以看到：

- 每个账号的套餐、登录邮箱
- 5 小时额度、每周额度、按模型计算的额度，以及多久后重置
- **推荐**：先用哪个账号、每个账号每 5 小时要用多少才能在重置前用完、哪个模型该换账号用

## 推荐是怎么算的

1. 每周额度到点就清零，用不完就浪费。对每个 Claude 账号算出"剩余额度 ÷ 距离重置的小时数"，这个值越大越紧迫，就优先推荐。
2. 5 小时额度或每周额度用到 98% 的账号暂时排除。
3. 某个模型的专属额度用到 80% 以上时，提示在这个账号上换别的模型，要用这个模型就切到另一个账号。

## 安装

需要 macOS 13+ 和 Swift 编译器（装 Xcode 或 `xcode-select --install` 即可）。

```bash
git clone https://github.com/dty00/QuotaPin.git
cd QuotaPin
./build.sh --install        # 编译并复制到 ~/Applications
open ~/Applications/QuotaPin.app
```

想开机自启：系统设置 → 通用 → 登录项 → `+` → 选 `~/Applications/QuotaPin.app`。

## 登录账号

QuotaPin 不需要你输入任何密码或 key，它直接复用命令行工具已有的登录：

| 服务 | 登录方式 | QuotaPin 读取哪里 |
|---|---|---|
| Claude（默认账号） | `claude auth login` | 钥匙串 `Claude Code-credentials` |
| Claude（第二个账号） | `CLAUDE_CONFIG_DIR=~/.claude-account2 claude auth login` | 钥匙串 `Claude Code-credentials-<hash>` |
| Codex | `codex login` | `~/.codex/auth.json` |

Claude 的登录过期时，QuotaPin 会调用 `claude auth status` 让 Claude Code 自己刷新，所以不会把你的 Claude Code 登出。

## 配置

首次运行会生成 `~/.config/quotapin/accounts.json`，菜单里的"编辑账号配置…"可以直接打开：

```json
{
  "accounts": [
    { "type": "claude", "name": "Claude 1", "short": "C1" },
    { "type": "claude", "name": "Claude 2", "short": "C2", "configDir": "~/.claude-account2" },
    { "type": "codex",  "name": "Codex",    "short": "X" }
  ],
  "claudePath": "~/.local/bin/claude",
  "refreshMinutes": 5
}
```

- `configDir`：Claude 账号对应的 `CLAUDE_CONFIG_DIR`（默认账号不填）；Codex 账号对应的 `CODEX_HOME`（默认 `~/.codex`）
- 改完点"立即刷新"即可生效

命令行调试：

```bash
~/Applications/QuotaPin.app/Contents/MacOS/QuotaPin --dump
```

## 注意

- 额度数据来自 Claude Code 和 Codex 内部使用的接口（`api.anthropic.com/api/oauth/usage`、`chatgpt.com/backend-api/wham/usage`），**没有公开文档**，官方随时可能修改。
- 登录凭据只在本机读取，只发给 Anthropic / OpenAI 自己的接口，不会发到其他地方。
- 本项目与 Anthropic、OpenAI 没有关联。

## License

MIT
