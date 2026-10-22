# onebox

**One host, one command, an internal developer platform.** onebox turns a single Linux machine
into the shared backbone a small team needs: HTTPS for every service with zero client setup, a
Git forge with CI, single sign-on, a secrets store, shared databases, and a Kubernetes cluster
driven by GitOps — all from one Ansible repository you can re-run at any time.

It is built to be **reused in very different environments** — a box under a desk, a VM in a
private DC, a cloud instance — so everything environment-specific lives in an inventory, every
component can be switched off, and providers (OS family, firewall, certificate source, DNS
provider, identity provider) are variables, not forks.

> Why each piece is the way it is: [ARCHITECTURE.md](ARCHITECTURE.md) and the
> [architecture decision records](docs/adr/).
> 中文說明：[README.zh-TW.md](README.zh-TW.md)

## What you get

| Component | What it provides | Role |
|---|---|---|
| `common` (always) | Packages, podman, firewalld with the container-network fix, lock-out-safe admin SSH | `common` |
| `edge` | The only process on 80/443: TLS for every hostname, LAN-only by default, a generated portal page | `caddy_edge`, `caddy_vhost` |
| `datastores` | Postgres, MySQL, Redis, NATS, etcd on a private container network | `datastores` |
| `openbao` | Secrets store with OIDC login and Kubernetes auth | `openbao` |
| `casdoor` | OIDC identity provider (or bring your own: Keycloak, Entra ID, Google…) | `casdoor` |
| `gitlab` | Git forge, container registry, git-over-SSH | `gitlab` |
| `gitlab-runner` | CI runner on the host: shell executor + rootless podman | `gitlab_runner` |
| `k3s` | Single-node Kubernetes | `k3s` |
| `k3s-gateway` | Cluster ingress (Traefik, Gateway API) bound to loopback behind the edge | `k3s_gateway` |
| `external-secrets` | Secrets from OpenBao into Kubernetes | `external_secrets` |
| `argocd` | GitOps control plane with SSO and RBAC | `argocd` |
| `argo-rollouts` | Blue-green and canary releases | `argo_rollouts` |
| `operators` | Personal admin accounts, SSH keys, sudo, break-glass accounts | `operators` |
| `storage` | Data and backup mounts, LVM volumes | `storage` |
| `tailscale` | Remote access for people outside the LAN | `tailscale` |

## Requirements

- One host running Rocky Linux / AlmaLinux / RHEL 9 or 10, Debian 13, or Ubuntu 24.04+.
- A DNS name per environment with one wildcard record, e.g. `*.dev.example.com → 192.0.2.10`.
- For publicly trusted certificates on a LAN-only host: API access to the DNS zone (DNS-01).
  Without it use `edge_tls_mode: internal` (own CA) or `files` (bring a certificate).
- Memory: ~4 GB for edge + datastores + SSO + secrets; add ~4 GB for GitLab and ~2 GB for
  k3s with Argo CD.

## Quick start

```bash
git clone https://github.com/<you>/onebox.git /opt/onebox && cd /opt/onebox
make init ENV=dev                         # copies inventories/example → inventories/dev
$EDITOR inventories/dev/group_vars/onebox/main.yml   # domain, IP, components, TLS
make secrets-missing                      # what still needs a value
make secrets-gen KEY=datastores_postgres_superuser_password   # random value
make secrets-set KEY=edge_cloudflare_api_token        # paste a value (no echo)
sudo make bootstrap                       # installs ansible-core, converges everything
```

Then, day to day:

```bash
sudo make check TAGS=gitlab   # dry run with diff for one component
sudo make gitlab              # converge one component
sudo make apply               # converge everything
sudo make status              # what is running
make test                     # static checks, no host needed
```

## How it fits together

```
make  (the only human interface)
  └─ deploy.sh  (bash only: resolves the environment, installs ansible-core on bootstrap)
       └─ ansible-playbook site.yml -i inventories/<env>
            preflight → common → [storage, operators, tailscale] → edge → datastores →
            k3s → casdoor → openbao → gitlab → gitlab-runner → k3s-gateway →
            external-secrets → argocd → argo-rollouts
```

- **One contract at the edge.** Caddy owns 80/443 and all TLS. Every service publishes on
  `127.0.0.1` and drops exactly one file into `/etc/caddy/conf.d/`. Nothing else edits the
  main Caddyfile.
- **Internal by default.** Every vhost answers 403 outside `onebox_internal_cidrs` — the LAN,
  plus the k3s pod network and the tailnet when those components run — unless the entry says
  `internal_only: false`.
- **Secrets never in the clear.** Values live in a gitignored (optionally vault-encrypted)
  `secrets.yml`, reach containers as podman secrets, and are hidden from Ansible output.

## Operations

Everything a person does on the host is a `make` target (`make help` lists them all).

| Target | What it does |
|---|---|
| `status` | Unit states, containers and unhealthy pods of the enabled components |
| `check TAGS=<c>` | Dry run with diff for one or more components |
| `secrets-gen` / `secrets-set` / `secrets-show` / `secrets-missing` | Edit `secrets.yml` safely (`KEY=…`) |
| `edge-root-ca` | Print the internal CA root to install on clients (`edge_tls_mode: internal`) |
| `datastores-status` | Engines, health and databases |
| `datastores-reset` → `datastores-reset-confirm` | Preview, then wipe application data (protect list kept) |
| `openbao-status`, `openbao-backup` | Seal state and auth methods; verified raft snapshot |
| `argocd-password` | Argo CD's initial admin password |
| `k3s-uninstall` → `k3s-uninstall-confirm ENV=<env>` | Preview, then remove the cluster |
| `tailscale-uninstall` → `tailscale-uninstall-confirm` | Preview, then leave the tailnet |
| `gitlab-backup`, `gitlab-logs`, `gitlab-reconfigure`, `gitlab-mail-test TO=…` | GitLab helpers (run on the host) |
| `gitlab-runner-logs`, `gitlab-runner-prune` | Runner helpers (run on the host) |
| `operator-password OP=<account>` | Set a password and force a change at next login |

Destructive operations always come in pairs: the plain target only previews, the `-confirm`
target acts.

## Configuration

Everything an environment decides lives in `inventories/<env>/group_vars/onebox/`:

```yaml
onebox_domain: dev.example.com
onebox_host_ip: 192.0.2.10
onebox_lan_cidrs: [192.0.2.0/24]
onebox_components: [edge, datastores, openbao, casdoor, gitlab, k3s, k3s-gateway, argocd]

edge_tls_mode: acme_dns          # acme_dns | acme_http | internal | files
edge_dns_provider: cloudflare    # route53 | cloudflare | rfc2136 | your own entry
common_admin_ssh_port: 2222      # hand port 22 to GitLab's git-over-SSH
```

Each role documents its own variables in `roles/<role>/README.md` and `defaults/main.yml`.
Variables shared between roles (hostnames, OIDC clients, the OpenBao ↔ External Secrets
names) are in [`group_vars/all/onebox.yml`](group_vars/all/onebox.yml).

## Testing without a host

`make test` renders every role's files for each scenario in [`tests/scenarios/`](tests/scenarios/)
(RHEL and Debian families, every TLS mode and DNS provider, components on and off — rendered
in parallel) and checks them with the tools the host would use:

| Check | Tool |
|---|---|
| Shell scripts | shellcheck |
| YAML, Ansible practices | yamllint, ansible-lint (production profile) |
| Playbooks | `ansible-playbook --syntax-check` |
| Quadlet units | podman's Quadlet generator `--dryrun` |
| Caddyfile | `caddy validate`, run with the exact binary the Dockerfile builds (plugins included) |
| systemd units, sudoers | `systemd-analyze verify`, `visudo -c` |
| Kubernetes manifests | kubeconform `-strict` with CRD schemas (rendered and `examples/`) |

All tools are pinned and installed into `.tools/` by `make tools`.

## Repository layout

```
site.yml                  one play per component
deploy.sh, Makefile       the operator interface
group_vars/all/           platform defaults and cross-role contracts
inventories/example/      template for an environment (make init copies it)
secrets.example.yml       every secret key, with placeholders
roles/                    one role per component (+ preflight, podman_quadlet, caddy_vhost)
playbooks/                operations (op.yml runs roles/<role>/tasks/<op>.yml), status, uninstalls
examples/gitops/          a GitOps repository skeleton for the cluster
tests/                    render harness, scenarios, pinned toolchain
docs/adr/                 architecture decision records
```

## License

MIT — see [LICENSE](LICENSE).
