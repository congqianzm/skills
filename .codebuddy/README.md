# CodeBuddy 适配层

本目录是 mattpocock/skills 的 **CodeBuddy 适配层**，解决以下问题：

- 上游技能为 Claude Code 设计（使用 `/skill` 路由、`disable-model-invocation` 等）
- CodeBuddy 有自己的技能格式和工具集（`ask_followup_question`、`Task` subagent 等）

## 架构设计

```
上游 skills/ (source of truth)
        │
        ▼
install-codebuddy.sh / .ps1 (自动转换)
        │
        ├── 去掉 Claude 特有语法
        ├── 解析 shell skill 并内联引用
        ├── 应用 patches/ 下的补丁
        │
        ▼
~/.codebuddy/skills/ (CodeBuddy 用户级技能)
```

**关键原则**：上游 `skills/` 是唯一事实来源。本目录只存放：
- `patches/` — 增量补丁（追加到转换后的技能末尾）
- 此 README

## 一键安装

### Linux / macOS

```bash
# 同步上游 + 转换 + 安装
./scripts/install-codebuddy.sh

# 仅重新安装（不拉取上游）
./scripts/install-codebuddy.sh --skip-sync

# 自定义安装目录
./scripts/install-codebuddy.sh --skills-dir ~/my-skills
```

### Windows (PowerShell)

```powershell
# 同步上游 + 转换 + 安装
./scripts/install-codebuddy.ps1

# 仅重新安装（不拉取上游）
./scripts/install-codebuddy.ps1 -SkipSync
```

## 安装的技能

| 技能名 | 上游来源 | 用途 |
|--------|----------|------|
| `/grill-with-docs` | engineering/grill-with-docs | 把想法磨清楚 + 构建领域模型 |
| `/to-prd` | engineering/to-spec | 把对话合成一份PRD |
| `/to-issues` | engineering/to-tickets | 把PRD切成独立issue |
| `/implement` | engineering/implement | 每个issue单开会话实现 |
| `/code-review` | engineering/code-review | 双轴代码评审收尾 |

## 推荐工作流

```
/grill-with-docs → /to-prd → /to-issues → /implement (逐个) → /code-review
```

## 如何追加自定义行为

在 `patches/<skill-name>.patch.md` 中写追加内容。脚本会在转换后的 SKILL.md 末尾追加补丁内容。

## 上游更新后怎么办

只需重新运行脚本：

```bash
# Linux/macOS
./scripts/install-codebuddy.sh

# Windows
./scripts/install-codebuddy.ps1
```

脚本会拉取最新上游 → 重新转换 → 重新应用补丁 → 覆盖安装。

## 系统要求

- **Git** — 用于同步上游
- **Bash 4+**（Linux/macOS）— 需要 `declare -A`（关联数组）支持
- **PowerShell 5+**（Windows）— 自带无需额外安装
