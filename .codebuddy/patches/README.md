# CodeBuddy Patches

此目录存放对上游技能的**增量补丁**。

## 工作原理

`scripts/install-codebuddy.ps1` 脚本会：
1. 从上游 `skills/` 目录读取原始 SKILL.md
2. 自动转换为 CodeBuddy 格式（去掉 Claude 特有语法）
3. 如果 `patches/<skill-name>.patch.md` 存在，将其内容**追加**到转换后的 SKILL.md 末尾

## 如何使用

创建 `<skill-name>.patch.md` 文件（skill-name 是输出名称，如 `to-prd`、`implement`）：

```markdown
## 额外规则（CodeBuddy 适配）

- 使用中文输出
- 对于 ask_followup_question，始终包含"自定义回答..."选项
```

## 注意

- 补丁只是追加内容，不会修改原文
- 如果需要完全替换某个技能，在 patches/ 下创建 `<skill-name>.override.md`（需要修改脚本支持）
- 上游更新后重新运行脚本即可自动合并
