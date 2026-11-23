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
| `VLESS_UUID` | VLESS 客户端 ID（UUID） | 是 |
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
