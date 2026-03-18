# MiniClaw

用 V 语言复刻 PicoClaw 的实用子集，直接面向 MiniMax + QQ 场景。

当前策略不是全量追平 PicoClaw，而是先做一个能稳定跑起来、能在 QQ 上收发消息、能调用 MiniMax 完成多轮工具型 Agent 任务的最小可用版本。

## 当前进度

已落地的骨架能力：

- 最小 V 项目结构已建立。
- `miniclaw onboard` 可生成默认配置和 workspace。
- `miniclaw status` 可检查当前配置状态。
- `miniclaw agent -p "..."` 在配置 API Key 后可直接调用 MiniMax 文本接口。
- `miniclaw agent` 已支持最小工具循环，可调用 `list_dir`、`read_file`、`write_file`、`exec`、`grep_search`。
- 会话已自动落盘到 workspace 下的 `sessions/`。
- 已增加基础自动化测试，并完成真实模型与工具链路验证。
- `--workspace` 命令行参数已支持覆盖默认 workspace，便于直接作用于当前项目目录。
- `miniclaw gateway --once` 已支持真实 QQ bootstrap：获取 access token、读取 bot profile、落盘状态。
- `miniclaw gateway` 已支持启动本地 QQ webhook 服务，完成回调验证签名和事件 ACK。
- webhook 收到 QQ 单聊/群聊消息事件后，已具备调用 MiniClaw 并被动回复的代码链路。
- workspace 已自动初始化 `sessions`、`memory`、`state`、`cron`、`skills` 目录，以及 `AGENTS.md`、`USER.md`、`HEARTBEAT.md`。
- 记忆系统已支持 `memory show|set|append|today|summarize|compact|prune|clear`，并把长期记忆、摘要和近期日记一起注入系统提示。
- 已具备 QQ 白名单、消息去重、处理中占位回复、网页授权回调页面和事件日志落盘能力。
- 公网 HTTPS webhook 已部署，当前服务由 systemd 常驻运行。

当前可直接验证：

```bash
./build.sh
v test src
./miniclaw onboard
./miniclaw status
./miniclaw agent -p "hello"
./miniclaw agent --workspace . -p "请使用工具读取 README.md 的第一行，并只输出这一行。"
./miniclaw agent --workspace . -p "必须使用 exec 工具执行命令 printf 'exec-smoke'，并且只输出命令结果本身。"
./miniclaw gateway --once
./miniclaw gateway
```

如果你要把当前工作区快速部署到 `bl` 并同时启用内置 MCP，可以直接运行：

```bash
./scripts/deploy_bl.sh
```

脚本会完成这些动作：

- 同步当前工作区到远端 `/bl/project/miniclaw/repo`
- 如果本地存在 `/tmp/v-master.zip`，就上传并在远端用它升级 V
- 在远端安装 `uvx`，并开启 `enable_mcp=true`
- 自动写入 `miniclaw-gateway` 的 systemd 资源限制：内存、CPU 和任务数
- 远端重建 MiniClaw，重启 `miniclaw-gateway`
- 依次验证 `web_search` 和 `understand_image` 两条内置 MCP 链路

## 配置示例

仓库内提供了一份可直接参考的示例配置文件：[examples/miniclaw.config.example](examples/miniclaw.config.example)。

推荐用法：

```bash
mkdir -p ~/.config/miniclaw
cp examples/miniclaw.config.example ~/.config/miniclaw/config
```

然后只在本机补齐你自己的敏感字段，不要把真实值写回仓库。

常用字段说明：

- `api_key`: MiniMax API Key，本地填写。
- `base_url`: 默认使用 `https://api.minimaxi.com/anthropic`，运行时会自动归一化到 Anthropic `messages` 接口。
- `ANTHROPIC_BASE_URL` / `MINICLAW_API_URL`: 可选环境变量覆盖 `base_url`，前者与文档保持一致，后者作为兼容别名保留。
- `model`: 默认是 `MiniMax-M2.7`。
- `mcp_config_path`: 额外 MCP 服务配置文件，默认是 `~/.config/miniclaw/mcp.json`。
- `enable_mcp`: 是否启用内置 MiniMax MCP，支持 `web_search`、`understand_image`。
- `mcp_base_path`: MiniMax MCP 的本地输出目录；留空时默认落到 workspace 下的 `state/minimax-mcp`。
- `mcp_resource_mode`: 传给 MiniMax MCP 的资源模式，默认 `url`。
- `qq_app_id`: QQ 机器人 AppID，本地填写。
- `qq_token`: QQ 机器人令牌，本地填写。
- `qq_app_secret`: QQ 机器人密钥，本地填写。
- `qq_webhook_path`: 消息事件回调路径。
- `qq_auth_callback_path`: 网页授权回调路径。
- `qq_allow_users`: 允许触发机器人的单聊用户列表，多个值用英文逗号分隔；留空表示不限制。
- `qq_allow_groups`: 允许触发机器人的群列表，多个值用英文逗号分隔；留空表示不限制。
- `qq_processing_text`: 长任务开始处理时先回复的占位文案。
- `memory_recent_days`: 系统提示里最近日记默认回看天数，默认是 `2`。
- `memory_recent_chars`: 系统提示里近期日记默认字符预算，默认是 `1600`。
- `memory_summary_max_lines`: 记忆摘要最大行数，默认是 `20`。
- `memory_summary_max_chars`: 记忆摘要最大字符数，默认是 `2000`。
- `memory_daily_entry_max_chars`: 单次写入日记时，单条 prompt/response 的截断长度，默认是 `500`。
- `memory_significance_threshold`: 记忆摘要的最低重要性分数，默认是 `3`。
- `memory_prune_keep_days`: `memory prune` 默认保留的天数，默认是 `14`。

## 记忆系统

MiniClaw 会把 workspace 下的记忆拆成三层：

- `memory/MEMORY.md`: 长期记忆，适合保存稳定偏好、约定、结论。
- `memory/SUMMARY.md`: 从近期日记里提炼出来的高价值摘要。
- `memory/YYYYMM/YYYYMMDD.md`: 按天落盘的原始日记，包含最近对话和响应。

当前默认会在这些场景自动使用记忆：

- `miniclaw agent` 运行时会把长期记忆、摘要和最近日记注入系统提示。
- `miniclaw agent` 成功返回后，会自动把本轮 prompt 和 response 写入当天日记，并补充摘要。
- `miniclaw memory show` 会直接展示当前拼装后的记忆上下文。

常用命令：

- `miniclaw memory show`: 查看当前记忆上下文。
- `miniclaw memory set -p "..."`: 覆盖长期记忆。
- `miniclaw memory append -p "..."`: 追加长期记忆。
- `miniclaw memory today -p "..."`: 追加当天日记。
- `miniclaw memory summarize [days]`: 基于最近几天日记刷新摘要。
- `miniclaw memory compact`: 去重并压缩长期记忆。
- `miniclaw memory prune [days]`: 删除过旧的日记文件。
- `miniclaw memory clear`: 清空长期记忆和摘要。

建议只在你确实需要调整行为时改这些参数，默认值已经适合一般的工作区使用场景。

## MCP 支持

MiniClaw 现在可以直接启用内置 MiniMax MCP，并且可以额外挂载你自己的 stdio MCP 服务。

启用内置 MCP 的最简单方式：

```bash
MINICLAW_API_KEY=your_key miniclaw agent --workspace . --mcp -p "请搜索 MiniMax MCP 文档，并总结要点。"
```

内置 MCP 会尝试通过 `uvx --native-tls minimax-coding-plan-mcp -y` 启动，并自动向模型暴露 `web_search` 和 `understand_image` 等工具。

如果你还想接入额外的 MCP 服务，可以创建 [examples/mcp.json.example](examples/mcp.json.example) 同结构的本地文件，并放到 `mcp_config_path` 指向的位置。当前只支持 `stdio` 类型服务。

## 目标边界

参考 PicoClaw，MiniClaw 第一阶段只覆盖下面这些能力：

- 单机单二进制运行。
- 本地 workspace + session 持久化。
- MiniMax 作为唯一默认模型提供商。
- QQ 作为唯一默认消息通道。
- 基础工具调用：读文件、写文件、列目录、执行命令、搜索文本。
- 一轮或多轮工具循环，而不是单纯问答。
- 最小配置、最小部署、最小依赖。

明确不在第一阶段做的内容：

- 多通道并发接入，例如 Telegram、Discord、LINE、微信企业号。
- 多提供商抽象到完全插件化。
- Docker、Web 控制台、MCP 市场、复杂权限系统。
- 语音、图像、视频、音乐等多模态能力。
- 分布式任务队列、远程数据库、集群化部署。

## 为什么先做 MiniMax + QQ

这条路线最符合当前资源约束：

- 你只有 MiniMax API Key，可以直接落地模型能力。
- 你只有 QQ 账号，优先做 QQ 才能最快验证真实使用链路。
- MiniMax 官方支持 Anthropic 兼容和 OpenAI 兼容接口，而 minimax-v 已经走通 Anthropic messages 路径，可以直接复用设计和部分实现思路。
- PicoClaw 的 provider 架构本质上也是协议族路由，不必一开始就复制它完整的多厂商矩阵。

## 对标 PicoClaw 时应该保留的核心能力

如果目标是“功能上像 PicoClaw”，真正有价值的是下面几块，而不是 README 里所有展示项：

1. Agent loop
   模型返回 tool use，本地执行工具，再把结果回灌模型，直到任务完成。

2. Workspace 模型
   所有会话、记忆、状态、计划、定时任务都围绕一个本地 workspace 目录组织。

3. Channel adapter
   QQ 只负责把外部消息转换成统一的 inbound event，再把 agent 输出发回去。

4. Config-driven provider
   模型提供商尽量走配置而不是硬编码，让后续加 OpenAI-compatible provider 成本低。

5. 安全边界
   工具默认限制在 workspace 内，危险命令要显式拦截。

6. 最小运维复杂度
   单机、单二进制、少依赖、低内存。

## 建议的实现路线

### 路线选择

不要从零写一个新的 Agent runtime。优先复用 minimax-v 已经验证过的能力边界：

- 配置加载。
- MiniMax Anthropic API 调用。
- 消息历史与工具循环。
- 本地工具执行与危险命令拦截。
- session / notes / todo / cron 等可拆分模块。

更合理的做法是：

- 把 minimax-v 看成 runtime base。
- 在 MiniClaw 内补上 PicoClaw 风格的 workspace、gateway、channel、配置模型。
- 第一阶段先只实现 QQ channel。

### 推荐架构

```text
CLI / daemon entry
  -> config loader
  -> workspace bootstrap
  -> provider registry
  -> agent service
  -> tool executor
  -> session store
  -> qq gateway adapter
```

推荐模块拆分：

- src/main.v: 入口与子命令分发。
- src/config.v: 配置结构、默认值、环境变量覆盖。
- src/workspace.v: 初始化 sessions、memory、state、cron 等目录。
- src/minimax_provider.v: MiniMax 适配器，先走 Anthropic 兼容接口。
- src/agent/\*.v: 对话状态、tool loop、命令执行策略。
- src/tools/\*.v: 文件、shell、search、todo、notes。
- src/channel/qq/\*.v: QQ 鉴权、收消息、发消息、事件转换。
- src/gateway/\*.v: channel lifecycle、router、health、日志。
- src/store/\*.v: session / state / cron 的本地持久化。

## TODO Plan

### Phase 0: 项目骨架

- [ ] 确定是直接基于 minimax-v 改造，还是抽取其中的 client / tools / sessions 模块复用。
- [x] 建立 MiniClaw 目录结构，避免后续把 channel、provider、agent 混在一起。
- [x] 定义最小 CLI：onboard、agent、gateway、status。
- [x] 约定默认 home 和 workspace 路径，例如 ~/.miniclaw 与 ~/.miniclaw/workspace。
- [x] 设计 config 文件格式，优先 JSON 或简洁 INI，不要一开始搞复杂嵌套兼容。

交付标准：能启动空程序，能生成配置和 workspace 目录。

### Phase 1: MiniMax Provider 落地

- [x] 直接复用 minimax-v 当前的 Anthropic messages 调用路径。
- [x] 抽出 MiniMaxClient 接口，屏蔽 HTTP 细节。
- [x] 支持非流式响应，先把稳定性跑通。
- [ ] 再补流式响应和 tool use 解析。
- [ ] 定义统一 message schema，避免 channel 层和 provider 层耦合。
- [x] 支持 model、api_key、api_url、max_tokens、temperature、timeout 配置项。
- [ ] 对 MiniMax 的错误码、限流、超时做统一重试和报错包装。

交付标准：CLI 模式下可以稳定完成一轮和多轮工具调用。

### Phase 2: Agent Runtime 最小闭环

- [x] 搬运或重写 minimax-v 的 tool loop，保留多轮执行能力。
- [x] 实现最小工具集：read_file、write_file、list_dir、exec、grep_search。
- [x] 增加 workspace 限制与危险命令黑名单。
- [x] 增加 session history 持久化。
- [ ] 增加 notes / todo 两个轻量持久化能力。
- [ ] 增加统一 command executor，避免每个 channel 自己解析命令。

交付标准：本地 agent 模式可用，具备 PicoClaw 最核心的“会做事”能力。

当前状态：已达成。

### Phase 3: QQ Channel MVP

- [x] 确认 QQ 开放平台接入方式：事件回调、签名校验、access token 获取、消息发送接口。
- [ ] 定义 ChannelAdapter 接口：start、stop、handle_event、send_message。
- [x] 实现 QQ inbound event -> internal message 的转换。
- [x] 实现 internal response -> QQ message 的发送。
- [x] 加 allow_from 白名单。
- [x] 增加最小去重和幂等，避免回调重放导致重复回复。
- [x] 增加长任务兜底策略：先回“处理中”，后续再补发结果，避免平台超时。

交付标准：QQ 上发一句话，能得到 MiniMax 回复；复杂请求能触发工具循环并回传结果。

当前状态：access token、bot profile、webhook 验证签名、事件 ACK、本地事件到 MiniClaw 回复链路均已实现，公网 HTTPS 回调地址也已部署。后续重点是补更完整的真实消息回归验证与日志观测，而不是再补一套接入方式。

### Phase 4: Gateway 与服务化运行

- [x] 实现 gateway 子命令，负责启动 QQ channel 和 agent service。
- [ ] 把 channel 与 agent 解耦，通过内部 event bus 或简化 router 连接。
- [x] 增加 health/status 输出。
- [x] 增加基本日志，包括请求 ID、channel、session、耗时、错误。
- [ ] 增加优雅退出和 token 缓存刷新。

交付标准：可以常驻运行，不只是命令行单次问答。

### Phase 5: PicoClaw 风格工作区能力

- [x] 初始化 workspace 目录结构：sessions、memory、state、cron、skills。
- [x] 增加 AGENTS.md、USER.md、HEARTBEAT.md 的读取约定。
- [ ] 让 system prompt 能叠加 workspace 里的 agent instructions。
- [ ] 增加定时任务最小实现，先支持简单 cron 或 interval。
- [ ] 增加状态文件，记录最近 channel / peer / active session。

交付标准：MiniClaw 从“能聊天的 bot”升级为“有长期上下文的个人 agent”。

### Phase 6: 稳定性与可维护性

- [x] 为 tools、qq adapter、session store 写基础单测。
- [ ] 为 provider 补单测。
- [ ] 增加集成测试：本地 prompt -> tool call -> result。
- [ ] 增加模拟 QQ webhook 测试。
- [ ] 控制二进制体积与启动时间，避免为了抽象把 PicoClaw 的轻量优势做没。
- [ ] 补文档：配置示例、QQ 接入说明、常见错误、部署说明。

交付标准：项目进入可持续迭代状态。

## 建议的开发优先级

按实用性排序，建议这样推进：

1. MiniMax CLI 单机可用。
2. Tool loop 可用。
3. Session / workspace 可用。
4. QQ channel 可用。
5. Gateway 常驻可用。
6. Heartbeat / cron / skills 等增强项。

原因很直接：如果先做 QQ 而本地 agent 不稳定，问题会被 channel 噪音掩盖，很难调试。先把本地链路打通，再挂 QQ，工程风险更低。

## 第一版最小可交付范围

只要下面这些做到，就已经算是“V 版 PicoClaw 实用 MVP”：

- [ ] onboard 生成配置和 workspace。
- [ ] agent 支持单次和交互模式。
- [ ] MiniMax 支持多轮 tool use。
- [ ] 工具支持读写文件、列目录、执行命令、搜索文本。
- [ ] QQ 能收发文本消息。
- [ ] session 能按用户或会话维度持久化。
- [ ] 基本安全限制可用。

这时候已经可以作为个人 QQ Agent 使用，不必等待多通道、多模态、MCP、复杂扩展系统完成。

## 明确不建议现在做的事

- 不要一开始照搬 PicoClaw 全部 channel。
- 不要先做 OpenAI / Zhipu / OpenRouter 多 provider 统一层。
- 不要先做 Docker Compose、Web 面板、插件市场。
- 不要先做语音、图片、视频。
- 不要先做“超通用”抽象，V 里过度抽象会把维护成本抬高。

## 当前最合理的下一步

当前主链路已经具备，本阶段更合理的顺序是：

1. 补 QQ webhook 和 gateway 的回归测试，先把现有能力守住。
2. 增加 health / metrics / 错误观测，缩短真实联调排障时间。
3. 继续收敛 provider 错误处理、超时和重试策略。
4. 再考虑 notes / todo / cron 这类增强能力。

这样能先稳住“可用的个人 QQ Agent”，再逐步往 PicoClaw 的长期工作区能力靠近。
