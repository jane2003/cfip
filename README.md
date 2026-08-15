# cfip

Cloudflare 官方 IP 优选。数据源 + 路由器脚本一套。

## 是什么

- `ip.txt` / `ipv6.txt`：Cloudflare 官方 anycast IP 段（CIDR），每周由 GitHub Actions 从 CF 官方 API 自动同步。
- `cdnip.sh`：路由器端脚本。下载 IP 段 → cfst 本地测速 → 选本地延迟最低的 IP → 更新到你的 CF 域名。

## 为什么是官方 IP

CF 官方 anycast IP 从国内直连延迟低（40～80ms）。反代 proxyip 走第三方 VPS 中转，多一跳，延迟 150ms 起。追求速度就用官方 IP。

## 路由器用法

```sh
mkdir -p /root/cfipopw
curl -sSL https://raw.githubusercontent.com/jane2003/cfip/master/cdnip.sh -o /root/cfipopw/cdnip.sh
chmod +x /root/cfipopw/cdnip.sh
bash /root/cfipopw/cdnip.sh
```

首次跑会下载 cfst 并测速。之后编辑 `/root/cfipopw/cf_config` 填入凭据：

```sh
CF_EMAIL="你的CF邮箱"
CF_KEY="你的Global API Key"
CF_ZONE="你的Zone ID"
CF_DOMAIN="你的域名"     # 更新 1.域名 2.域名 ... N.域名
CF_COUNT="10"            # 更新前 N 个
CF_TG_TOKEN="..."        # 可选，TG 推送
CF_TG_ID="..."
```

再加 cron：

```sh
0 7 * * * cd /root && bash cdnip.sh --run
```

## 参数说明（cf_config）

| 变量 | 默认 | 说明 |
|------|------|------|
| CF_DOMAIN | zbs969.dpdns.org | 主域名，更新 1~N.域名 |
| CF_COUNT | 10 | 更新域名数量 |
| CF_THREADS | 200 | cfst 测速线程 |
| CF_DN_COUNT | 10 | 每 IP 下载测速次数 |
| CF_TL | 300 | 延迟上限 ms |
| CF_IPV | 4 | 4=IPv4 6=IPv6 |
| CF_SPEED_URL | cdnjs 官方地址 | 测速下载地址，国内可达 |

## 注意

- 测速必须在路由器本地跑。GitHub Actions 测速机在国外，结果对国内线路不准。
- cfst 默认测速地址 `speed.cloudflare.com` 国内不通，脚本已改用 `cdnjs.cloudflare.com`。
- CF API（api.cloudflare.com）若不通，加 hosts：`104.18.34.200 api.cloudflare.com`。
