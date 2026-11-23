# base-one — VLESS over WebSocket 出口节点（Komuta PaaS）

在 [Komuta](https://www.komuta.io) 上部署的轻量 VLESS+WS 出口节点。

## 架构

```
客户端 ──VLESS/WS──> Komuta 公网域名 (TLS 终止)
                        └─> Nginx :80  ──>  Xray VLESS/WS :10000 (仅本地)
                                                     └─> 目标站点
```

- **Nginx** 负责静态页 + WebSocket 反代（`location = ${WS_PATH}` 精确匹配）。
- **Xray** 只监听 `127.0.0.1:10000`，容器外不可直连。
- 容器内**不启用 TLS**，TLS 由 Komuta 平台在入口终止。

## 环境变量

| 变量 | 说明 | 必填 |
|---|---|---|
| `VLESS_UUID` | VLESS 客户端 ID。若给定值不是合法 UUID（平台 secret 常是随机串），启动时会用 SHA-256 确定性派生为 UUID v4，实际生效值见 `${WS_PATH}/node.json` | 是 |
| `WS_PATH` | WebSocket 路径，默认 `/r9q2x7b6p4w8` | 否 |

`entrypoint.sh` 用 `envsubst` 渲染 `config/*.template` 生成运行时配置，
并以 `xray run -test` + `nginx -t` 做启动前自检，任一失败则容器不启动。

## 本地运行

```bash
docker build -t base-one .
docker run -d --name base-one -p 8080:80 \
  -e VLESS_UUID="$(cat /proc/sys/kernel/random/uuid)" \
  -e WS_PATH=/r9q2x7b6p4w8 \
  base-one
```

## Komuta 部署

`komuta.yaml` 是本项目在 Komuta 上的 Stack 清单：

```bash
komuta_validate_stack --manifest komuta.yaml
komuta_plan_stack      --manifest komuta.yaml
komuta_apply_stack     --planId <PLAN_ID>
```

镜像在 `build.strategy: dockerfile` 下由平台从本仓库的 `Dockerfile` 构建，
推送到 Komuta 自有 registry 后以 `dz-nano`（免费套餐）运行。

## 平台适配要点（踩过的坑）

| 现象 | 根因 | 处理 |
|---|---|---|
| 容器反复重启，退出码 23 | 平台 secret 生成的是任意长度随机串，而 VLESS 的 `id` 必须是 UUID | `entrypoint.sh` 做确定性规范化：合法 UUID 透传，其余用 SHA-256 派生 UUID v4；原始 secret 始终只存在平台密钥库 |
| 公网 503 `Connection refused` | 平台 Service 的 `targetPort` 在创建时固定为 **80**，`revise` 不支持原地改端口 | 镜像给 `nginx` 加 `cap_net_bind_service`，容器同时监听 80 与 8080；启动时用空闲特权端口 81 探测绑定能力 |
| `could not open error log file` 告警 | `/var/lib/nginx` 属 `nginx:nginx 750` | 构建时放开 `a+rwX` |
| 非 root 下 `[warn] the "user" directive ... ignored` | 配置里写死了 `user nginx;` | 移除该指令，进程身份由容器运行时决定 |
| 改代码后 `stack apply` 仍是 `Noop` | Stack 只声明与上次应用一致的字段，不触发重建 | 用 `komuta_trigger_pipeline`（day-2 redeploy）单独构建发布 |

## 节点参数接口

`GET ${WS_PATH}/node.json` 返回运行时生成的有效 UUID、WS 路径与传输参数，
根路径页面会自动拉取并展示可直接导入客户端的 `vless://` 链接。
`GET /healthz` 用于容器健康检查。
