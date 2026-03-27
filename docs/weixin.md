# Weixin 接入说明

MiniClaw 的 Weixin 接入采用本地后端协议。当前实现不是直接调用微信官方 SDK，而是提供一个本地 HTTP 后端，让微信通道把消息交给 MiniClaw，再把回复送回去。

## 当前支持

- `miniclaw weixin` 启动 Weixin 后端协议服务。
- `miniclaw weixin send --to-user USER_ID -p "..."` 将一条文本消息排入发送队列。
- `miniclaw weixin reply --to-user USER_ID -p "..."` 先跑 MiniMax Agent，再把结果排入发送队列。
- `miniclaw weixin ingest --from-user USER_ID -p "..."` 模拟“微信收到一句话”，然后自动回复。

## 配置

在 [examples/miniclaw.config.example](../examples/miniclaw.config.example) 中补齐这些字段：

- `weixin_host`
- `weixin_port`
- `weixin_base_path`
- `weixin_processing_text`

默认值已经适合本地开发：

- `weixin_host=127.0.0.1`
- `weixin_port=18081`
- `weixin_base_path=/weixin`
- `weixin_processing_text=收到，处理中，请稍候。`

## 本地闭环

当前最小闭环是：

1. 微信侧消息进入 `ingest` 入口。
2. MiniClaw 运行现有 `agent` 流程。
3. 回复文本写入本地发送队列。
4. `getUpdates` 拉取时返回这条回复。

这意味着本地已经能验证“收到一句话 -> MiniClaw 自动回复”的主流程。

## 输入格式

`ingest` 目前兼容这几种消息包裹：

- 顶层字段：`from_user_id`、`context_token`、`text`
- `msg` 包裹：`{"msg":{...}}`
- `d` 包裹：`{"d":{...}}`
- `item_list` 文本项：`{"item_list":[{"type":1,"text_item":{"text":"..."}}]}`

推荐优先传 `msg` 包裹，因为它最接近后续真实 Weixin 消息适配。

## 启动步骤

```bash
./miniclaw onboard
./miniclaw weixin
```

## 二维码怎么生成

这个二维码由 MiniClaw 本地生成。

最短步骤：

```bash
./miniclaw channels login --channel weixin
```

`miniclaw channels login --channel weixin` 会直接在 MiniClaw 里生成一次本地配对会话，并写出一张 SVG 图片到 `state/weixin_login_qr.svg`。你可以用浏览器打开这张图，或者复制 pairing URL 继续后续接入，登录状态会写入本地。

`miniclaw://weixin/login?channel=weixin&session=WX-...` 不是网页地址，而是本地配对会话标识。当前版本里它用于：

- 作为二维码实际承载的内容。
- 作为本地状态文件里可追踪的 session 值。
- 作为后续接入真实客户端时的对接参数。

如果你只是想确认它的含义，直接看 `pairing url` 那一行即可；它不是普通网页地址。

你也可以直接打开 `state/weixin_login_qr.svg`，浏览器里会显示清晰的二维码图片和 session 信息。

验证自动回复：

```bash
./miniclaw weixin ingest --from-user user-1 -p "帮我总结一下今天的工作"
./miniclaw weixin send --to-user user-1 -p "hello"
```

HTTP 级示例：

```bash
curl -sS -X POST http://127.0.0.1:18081/weixin/ingest \
  -H 'Content-Type: application/json' \
  -d '{"msg":{"from_user_id":"user-1","context_token":"ctx-1","item_list":[{"type":1,"text_item":{"text":"帮我总结一下今天的工作"}}]}}'
```

## 协议端点

当前服务暴露以下端点：

- `POST /weixin/getUpdates`
- `POST /weixin/sendMessage`
- `POST /weixin/getUploadUrl`
- `POST /weixin/getConfig`
- `POST /weixin/sendTyping`
- `POST /weixin/ingest`

其中 `ingest` 是本地桥接入口，不是标准协议端点，但它能把“收到消息”这一步接进 MiniClaw 的自动回复链路。

## 后续可继续完善的点

- 把 `ingest` 的输入改成更完整的 Weixin 消息结构。
- 给每个会话加更稳定的上下文键，避免多用户互相串话。
- 把回复队列改成持久化的 per-user outbox。
