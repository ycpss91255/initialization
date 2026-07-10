# 开发工作流

> 此文件扩展 [common/git-workflow.md](./git-workflow.md)，包含 git 操作之前的完整功能开发流程。

功能实现工作流描述了开发管道：研究、规划、TDD、代码审查，然后提交到 git。

## 功能实现工作流

0. **研究与重用** _(任何新实现前必需)_
   - **GitHub 代码搜索优先：** 在编写任何新代码之前，运行 `gh search repos` 和 `gh search code` 查找现有实现、模板和模式。
   - **库文档其次：** 使用 Context7 或主要供应商文档确认 API 行为、包使用和版本特定细节。
   - **仅当前两者不足时使用 Exa：** 在 GitHub 搜索和主要文档之后，使用 Exa 进行更广泛的网络研究或发现。
   - **检查包注册表：** 在编写工具代码之前搜索 npm、PyPI、crates.io 和其他注册表。首选久经考验的库而非手工编写的解决方案。
   - **搜索可适配的实现：** 寻找解决问题 80%+ 且可以分支、移植或包装的开源项目。
   - 当满足需求时，优先采用或移植经验证的方法而非从头编写新代码。

1. **先规划**
   - 使用 **planner** 代理创建实现计划
   - 编码前生成规划文档：PRD、架构、系统设计、技术文档、任务列表
   - 识别依赖和风险
   - 分解为阶段

2. **TDD 方法**
   - 使用 **tdd-guide** 代理
   - 先写测试（RED）
   - 实现以通过测试（GREEN）
   - 重构（IMPROVE）
   - 验证 80%+ 覆盖率

3. **代码审查**
   - 编写代码后立即使用 **code-reviewer** 代理
   - 解决关键和高优先级问题
   - 尽可能修复中优先级问题

4. **提交与推送**
   - 详细的提交消息
   - 遵循约定式提交格式
   - 参见 [git-workflow.md](./git-workflow.md) 了解提交消息格式和 PR 流程

5. **审查前检查**
   - 验证所有自动化检查（CI/CD）已通过
   - 解决任何合并冲突
   - 确保分支已与目标分支同步
   - 仅在这些检查通过后请求审查

## GitHub Issue / PR 审查批准（`gh ... create` 前必需）

`gh issue create|edit` 与 `gh pr create|edit` 会把内容发布到一个公开且被
索引的仓库。用户必须在内容落地之前看到并批准草稿。由
`.claude/hook/enforce_gh_review_approval.sh`（Bash 的 PreToolUse）强制执行：
在会话记录（transcript）包含明确的用户批准短语之前，拒绝这些命令 --
与 `enforce_shellcheck_disable_approval.sh` 相同的基于记录的批准机制。

默认流程：

1. 用用户的工作语言（zh-TW）把草稿写到本地文件，例如 `/tmp/<slug>.zh.md`。
2. 展示该路径（以及／或简短摘要），请用户审查。
3. 用户批准后，把批准的内容翻译为英文。
4. 用英文的 `--body-file` 运行 `gh issue create` / `gh pr create`。
   英文强制检查（`enforce_gh_english.sh`）仍会运行。

批准短语（大小写不敏感；任意一个即可）：

- `approve issue` / `issue ok` -> 授权 `gh issue create|edit`
- `approve pr` / `pr ok` -> 授权 `gh pr create|edit`
- `skip review` -> 显式跳过；当用户表示直接开 issue／PR 时授权两种。

规范 token 保持英文，使钩子检查与语言无关。
应急绕过（会在 shell 历史留下审计痕迹）：`ECC_ALLOW_GH_REVIEW=1`。
