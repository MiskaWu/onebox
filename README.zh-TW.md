# onebox

**一台主機、一個指令，撐起整套內部開發平台。** onebox 把一台 Linux 機器變成小團隊需要的共用基礎：
每個服務都有免設定就受信任的 HTTPS、附 CI 的 Git 平台、單一登入、機密管理、共用資料庫，
以及用 GitOps 驅動的 Kubernetes 叢集——全部由同一個 Ansible repo 管理，隨時可以重跑。

它是為了**在各種不同環境重複使用**而設計的：桌下的一台實體機、私有機房的 VM、雲端主機都適用。
所以環境特有的設定全部集中在 inventory，每個組件都能關掉，作業系統、防火牆、憑證來源、
DNS 供應商、身分提供者這些差異都是變數，而不是分支出另一份程式碼。

> 每個設計背後的理由：[ARCHITECTURE.md](ARCHITECTURE.md) 與[架構決策紀錄（ADR）](docs/adr/)。
> English: [README.md](README.md)

## 包含哪些組件

| 組件 | 提供什麼 | Role |
|---|---|---|
| `common`（一定會跑） | 套件、podman、firewalld（含容器網路修正）、不會把自己鎖在門外的 SSH 換埠 | `common` |
| `edge` | 唯一占用 80/443 的程序：所有網域的 TLS、預設只對內網開放、自動產生的入口頁 | `caddy_edge`、`caddy_vhost` |
| `datastores` | PostgreSQL、MySQL、Redis、NATS、etcd，跑在私有的容器網路上 | `datastores` |
| `openbao` | 機密管理，支援 OIDC 登入與 Kubernetes 驗證 | `openbao` |
| `casdoor` | OIDC 身分提供者（也可以換成 Keycloak、Entra ID、Google 等） | `casdoor` |
| `gitlab` | Git 平台、container registry、git-over-SSH | `gitlab` |
| `gitlab-runner` | 跑在主機上的 CI runner：shell executor 搭配 rootless podman | `gitlab_runner` |
| `k3s` | 單節點 Kubernetes | `k3s` |
| `k3s-gateway` | 叢集入口（Traefik、Gateway API），綁在 loopback、由邊緣轉入 | `k3s_gateway` |
| `external-secrets` | 把 OpenBao 的機密同步成 Kubernetes Secret | `external_secrets` |
| `argocd` | GitOps 控制面，含 SSO 與權限控管 | `argocd` |
| `argo-rollouts` | 藍綠與金絲雀發布 | `argo_rollouts` |
| `operators` | 個人管理帳號、SSH 金鑰、sudo、緊急用的本機帳號 | `operators` |
| `storage` | 資料與備份掛載點、LVM 磁碟區 | `storage` |
| `tailscale` | 讓不在內網的人連進來 | `tailscale` |

## 需求

- 一台主機：Rocky Linux／AlmaLinux／RHEL 9 或 10、Debian 13、Ubuntu 24.04 以上。
- 每個環境一個網域，加一筆萬用字元 DNS 記錄，例如 `*.dev.example.com → 192.0.2.10`。
- 只在內網解析的主機若要拿到公開受信任的憑證，需要能用 API 操作那個 DNS zone（DNS-01）。
  沒有的話改用 `edge_tls_mode: internal`（自己的 CA）或 `files`（自備憑證）。
- 記憶體：邊緣＋資料庫＋SSO＋機密管理約 4 GB；GitLab 再加約 4 GB；k3s 加 Argo CD 再加約 2 GB。

## 快速開始

```bash
git clone https://github.com/<you>/onebox.git /opt/onebox && cd /opt/onebox
make init ENV=dev                         # 從 inventories/example 複製出 inventories/dev
$EDITOR inventories/dev/group_vars/onebox/main.yml   # 網域、IP、要開的組件、TLS 方式
make secrets-missing                      # 列出還沒填的機密
make secrets-gen KEY=datastores_postgres_superuser_password   # 產生隨機值
make secrets-set KEY=edge_cloudflare_api_token                # 貼上值（不回顯、不進 shell 歷史）
sudo make bootstrap                       # 裝好 ansible-core，然後收斂整台主機
```

日常操作：

```bash
sudo make check TAGS=gitlab   # 只對一個組件做 dry run 並顯示差異
sudo make gitlab              # 只收斂一個組件
sudo make apply               # 收斂全部
sudo make status              # 看目前跑起來的狀態
make test                     # 靜態檢查，不需要主機
```

## 整體怎麼串起來

```
make  （人唯一需要用的介面）
  └─ deploy.sh  （只用 bash：決定環境、首次執行時安裝 ansible-core）
       └─ ansible-playbook site.yml -i inventories/<env>
            preflight → common → [storage, operators, tailscale] → edge → datastores →
            k3s → casdoor → openbao → gitlab → gitlab-runner → k3s-gateway →
            external-secrets → argocd → argo-rollouts
```

- **邊緣只有一個契約。** Caddy 擁有 80/443 和所有 TLS。每個服務都只綁 `127.0.0.1`，
  並在 `/etc/caddy/conf.d/` 放剛好一個檔案；沒有任何服務會去改主要的 Caddyfile。
- **預設只對內開放。** 除非該筆設定寫了 `internal_only: false`，否則來源不在
  `onebox_internal_cidrs` 的請求一律回 403。這份清單是內網網段，再自動加上有啟用時的
  k3s pod 網段與 Tailscale 網段。
- **機密不以明文流動。** 值放在 gitignore 掉的 `secrets.yml`（可選擇用 ansible-vault 加密），
  以 podman secret 交給容器，並且不會出現在 Ansible 的輸出裡。

## 維運指令

人在主機上要做的事都是一個 `make` 目標（`make help` 會全部列出）。

| 目標 | 做什麼 |
|---|---|
| `status` | 已啟用組件的服務狀態、容器、異常的 pod |
| `check TAGS=<組件>` | 對一個或多個組件 dry run 並顯示差異 |
| `secrets-gen`／`secrets-set`／`secrets-show`／`secrets-missing` | 安全地編輯 `secrets.yml`（`KEY=…`） |
| `edge-root-ca` | 印出內部 CA 的根憑證，裝到用戶端（`edge_tls_mode: internal`） |
| `datastores-status` | 各資料庫引擎、健康狀態、資料庫清單 |
| `datastores-reset` → `datastores-reset-confirm` | 先預覽，再清掉應用資料（保護清單內的保留） |
| `openbao-status`、`openbao-backup` | 封存狀態與驗證方式；經過驗證的 raft 快照 |
| `argocd-password` | Argo CD 的初始管理員密碼 |
| `k3s-uninstall` → `k3s-uninstall-confirm ENV=<環境>` | 先預覽，再移除整個叢集 |
| `tailscale-uninstall` → `tailscale-uninstall-confirm` | 先預覽，再離開 tailnet |
| `gitlab-backup`、`gitlab-logs`、`gitlab-reconfigure`、`gitlab-mail-test TO=…` | GitLab 輔助指令（在主機上執行） |
| `gitlab-runner-logs`、`gitlab-runner-prune` | Runner 輔助指令（在主機上執行） |
| `operator-password OP=<帳號>` | 設定密碼，並要求下次登入時更換 |

有破壞性的操作一律成對：不帶後綴的只預覽，`-confirm` 才真的執行。

## 設定

每個環境要決定的事情，都放在 `inventories/<env>/group_vars/onebox/`：

```yaml
onebox_domain: dev.example.com
onebox_host_ip: 192.0.2.10
onebox_lan_cidrs: [192.0.2.0/24]
onebox_components: [edge, datastores, openbao, casdoor, gitlab, k3s, k3s-gateway, argocd]

edge_tls_mode: acme_dns          # acme_dns | acme_http | internal | files
edge_dns_provider: cloudflare    # route53 | cloudflare | rfc2136 | 你自己加的一筆
common_admin_ssh_port: 2222      # 把 22 讓給 GitLab 的 git-over-SSH
```

每個 role 的變數說明在 `roles/<role>/README.md` 與 `defaults/main.yml`。跨 role 共用的變數
（主機名稱、OIDC 用戶端、OpenBao 與 External Secrets 之間的對應名稱）在
[`group_vars/all/onebox.yml`](group_vars/all/onebox.yml)。

## 不需要主機的測試

`make test` 會為 [`tests/scenarios/`](tests/scenarios/) 裡的每個情境，把所有 role 要寫的檔案
渲染出來。這些情境涵蓋 RHEL 與 Debian 兩個系列、每種 TLS 模式與 DNS 供應商、組件開關的組合，
並且平行渲染。接著用主機上實際會用的工具逐一檢查：

| 檢查對象 | 工具 |
|---|---|
| Shell 腳本 | shellcheck |
| YAML、Ansible 寫法 | yamllint、ansible-lint（production profile） |
| Playbook | `ansible-playbook --syntax-check` |
| Quadlet unit | podman 的 Quadlet 產生器 `--dryrun` |
| Caddyfile | `caddy validate`，用 Dockerfile 實際編出的同一顆 binary（含外掛）來跑 |
| systemd unit、sudoers | `systemd-analyze verify`、`visudo -c` |
| Kubernetes manifest | kubeconform `-strict`，含 CRD schema（渲染結果與 `examples/`） |

所有工具都固定版本，由 `make tools` 安裝到 `.tools/`。

## 目錄結構

```
site.yml                  每個組件一個 play
deploy.sh, Makefile       維運介面
group_vars/all/           平台預設值與跨 role 的契約
inventories/example/      環境範本（make init 會複製它）
secrets.example.yml       所有機密鍵與佔位值
roles/                    每個組件一個 role（另有 preflight、podman_quadlet、caddy_vhost）
playbooks/                維運操作（op.yml 執行 roles/<role>/tasks/<op>.yml）、狀態、移除
examples/gitops/          給叢集用的 GitOps repo 骨架
tests/                    渲染測試、情境、固定版本的工具鏈
docs/adr/                 架構決策紀錄
```

## 授權

MIT，見 [LICENSE](LICENSE)。
