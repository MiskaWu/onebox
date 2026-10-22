# onebox architecture

onebox turns one Linux host into the internal platform a small team needs: HTTPS for every
service, a Git forge with CI and a container registry, single sign-on, a secrets store, shared
datastores, and a single-node Kubernetes cluster driven by GitOps. One host serves one
environment; another environment is another host with its own inventory
([ADR 0001](docs/adr/0001-one-host-per-environment-one-repository.md)).

Rules for changing the repository are in [CLAUDE.md](CLAUDE.md); operating it is in
[README.md](README.md); the reasons behind each design choice are in [docs/adr/](docs/adr/).

## The picture

Request paths:

```
                        ┌────────────── internet: outbound only ──────────────┐
                        │   ACME CA                DNS provider API (DNS-01)    │
                        └──────▲──────────────────────────▲────────────────────┘
                               │                          │
 people on the LAN /           │                          │
 mesh VPN ── https :443 ──►  ┌─┴──────────────────────────┴─────────────────────────┐
                             │ EDGE: Caddy under host systemd, sole owner of 80/443 │
                             │   TLS for <domain> and every *.<domain> name         │
                             │   403 outside onebox_internal_cidrs unless opened    │
                             │   import conf.d/*.caddy — one drop-in per service    │
                             └───┬───────────┬───────────┬───────────┬──────────────┘
              reverse_proxy      │ :8081     │ :8000     │ :8200     │ :31080
              127.0.0.1:<port>   ▼           ▼           ▼           ▼  (*.apps.<domain>, argocd.)
                             ┌────────┐  ┌────────┐  ┌────────┐  ┌───────────────────────────┐
                             │ GitLab │  │Casdoor │  │OpenBao │  │ k3s gateway: Traefik       │
                             │ podman │  │ podman │  │ podman │  │ hostNetwork, 127.0.0.1     │
                             └────────┘  └────────┘  └────────┘  │ Ingress + Gateway API      │
                                                                 └─────────────┬─────────────┘
                                                                               ▼ Host header
                                                                 pods: Argo CD, External Secrets,
                                                                 Argo Rollouts, workloads

 git clients ── ssh :22 ───► GitLab git-over-SSH   (published port: DNAT, not firewall-filtered)
 operators  ─── ssh :2222 ─► host sshd (admin)     (SSH tunnels to 127.0.0.1 ports)

 ┌─ onebox-data: private podman network, fixed subnet; nothing published beyond 127.0.0.1 ──┐
 │   postgres     mysql     redis ×3     nats     etcd                                       │
 │   ▲ podman services join the network and use container names (postgres:5432)             │
 │   ▲ pods use a Service name → selectorless Service + EndpointSlice → fixed container IP   │
 │   ▲ people use ssh -L <port>:127.0.0.1:<port> through the admin sshd                     │
 └────────────────────────────────────────────────────────────────────────────────────────────┘
```

Control and data relationships:

```
 CI job ──► gitlab-runner (host, rootless podman) ──push──► registry.<domain> (GitLab)
               │ manual bump job commits the new tag
               ▼
 GitOps repo (GitLab) ◄── read ── Argo CD (k3s) ── apply ──► <tenant>-<env> namespaces
                                                                  │ ExternalSecret
 OpenBao (host) ◄── https://bao.<domain> via the edge ── External Secrets ──► Kubernetes Secrets
       ▲  Kubernetes auth: OpenBao reviews External Secrets' own service-account token

 OIDC issuer (bundled Casdoor or any OIDC IdP) ◄── sign-in from GitLab, Argo CD, OpenBao
```

Two-layer ingress: the edge knows hostnames and loopback ports, never pods; the gateway knows
pods, never certificates ([ADR 0004](docs/adr/0004-host-native-edge-proxy.md),
[ADR 0015](docs/adr/0015-loopback-cluster-gateway.md)). The only listeners on a routable
address are the edge (80/443), the admin sshd, git-over-SSH, and whatever the inventory opts in.

## Components

`onebox_components` selects what runs; `onebox_component_requires` in
[`group_vars/all/onebox.yml`](group_vars/all/onebox.yml) is the dependency graph that preflight
enforces.

| Component | Role | Owns |
|---|---|---|
| *(always)* | `common` | Base packages, podman ≥ 4.9, sshd and the lock-out-safe admin port move, firewalld with netavark's reload hook, SELinux port label, optional smartd, the shared `firewall_open.yml` helper |
| `operators` | `operators` | Personal admin accounts, SSH keys, sudo, the operators group, console-only break-glass accounts |
| `storage` | `storage` | Data and backup mounts, logical volumes carved from free space, mount guards. Fast storage for random-I/O data (repositories, databases, build caches), large disks for cold blobs, backups on a different disk |
| `tailscale` | `tailscale` | Mesh VPN client for remote people; a previewed uninstall |
| `edge` | `caddy_edge` (+ `caddy_vhost` in every service play) | Caddy build and binary, `caddy.service`, main Caddyfile and snippets, DNS credentials in `caddy.env`, the admin socket, the portal page, 80/443 in the firewall |
| `datastores` | `datastores` | The `onebox-data` network; PostgreSQL, MySQL, a three-node Redis cluster, NATS and etcd containers with fixed addresses; superusers only |
| `openbao` | `openbao` | OpenBao container (loopback 8200), raft storage, static auto-unseal, KV mount, policies, OIDC and Kubernetes auth; vhost `bao.<domain>` |
| `casdoor` | `casdoor` | Casdoor container (loopback 8000), its database in the shared PostgreSQL, the OIDC applications from `onebox_oidc_clients`; vhost `sso.<domain>` |
| `gitlab` | `gitlab` | GitLab container (loopback HTTP 8081, git-over-SSH on host port 22 once the admin sshd has moved), container registry, OIDC sign-in; vhosts `gitlab.` and `registry.<domain>` |
| `gitlab-runner` | `gitlab_runner` | Host-native runner account and service, rootless podman, a container-executor runner and a tag-gated shell runner |
| `k3s` | `k3s` | k3s server, group-readable admin kubeconfig, the auto-deploy manifests directory |
| `k3s-gateway` | `k3s_gateway` | Traefik `HelmChart` (hostNetwork, `127.0.0.1:31080`), Gateway API CRDs, opt-in non-HTTP entrypoints; vhost catch-all `*.apps.<domain>` |
| `external-secrets` | `external_secrets` | External Secrets Operator, the store pointing at OpenBao, the image pull `ClusterExternalSecret` |
| `argocd` | `argocd` | Argo CD chart, SSO and RBAC, AppProjects per tenant, repository credentials, the EndpointSlice exclusion override; vhost `argocd.<domain>` (served through the gateway) |
| `argo-rollouts` | `argo_rollouts` | Rollouts controller and the pinned Gateway API traffic plugin |

Primitives used by the roles above: `preflight` (component graph, OS support, ansible-core
version, each component's own checks), `podman_quadlet` (one container or network as a Quadlet
unit), `caddy_vhost` (one drop-in and one portal card per service).

## Contracts

These are the only interfaces between roles. Changing one is a cross-role change and belongs in
one commit.

### Edge drop-ins

The edge's main Caddyfile defines global TLS policy, the snippets `onebox_site` and
`onebox_internal_only`, and `import /etc/caddy/conf.d/*.caddy`. A service play includes
`caddy_vhost` with `caddy_vhost_name` (file name and portal card name) and
`caddy_vhost_entries`:

| Key | Required | Meaning |
|---|---|---|
| `hostname` | yes | Site address; platform services use flat names, workloads live under `*.apps.<domain>` |
| `upstream` | yes | `127.0.0.1:<port>` (several upstreams separated by spaces) |
| `title`, `description` | no | Portal card text |
| `portal` | no | List on the portal page (default `true`; catch-alls set `false`) |
| `internal_only` | no | Default `edge_internal_only_default` (`true`): 403 outside the allowed ranges |
| `allow_cidrs` | no | Allowed ranges for this entry (default `onebox_internal_cidrs`) |
| `lb_try_duration` | no | Retry while the upstream restarts instead of answering 502 |
| `stream_close_delay` | no | Keep WebSockets open across reloads for this long |
| `directives` | no | Extra lines inside the site block |

Every generated site imports `onebox_site` and contains no `tls` directive. Nothing but
`caddy_edge` writes the main Caddyfile; `edge_sites` is reserved for sites that belong to no
service. Config changes reload through the admin socket (`edge_admin_mode: unix`) or restart
the edge (`off`).

### Loopback publishing

| Listener | Address | Notes |
|---|---|---|
| Service HTTP ports (GitLab 8081, Casdoor 8000, OpenBao 8200 by default) | `127.0.0.1` | Reached only through the edge |
| Cluster gateway `k3s_gateway_http_port` (31080) | `127.0.0.1` | Traefik on hostNetwork; no Kubernetes Service |
| Datastores (engine default ports) | `127.0.0.1` | Host tools and SSH tunnels; pods use the data network |
| Kubernetes API 6443 | host | Not opened to the LAN; remote `kubectl` through SSH |
| git-over-SSH | host `:22` | Explicit exception: DNAT'd, cannot be source-filtered by firewalld |
| Admin sshd | host `:common_admin_ssh_port` | Firewall-filterable (`common_admin_ssh_allowed_cidrs`) |
| Non-HTTP gateway entrypoints | named address | Opt-in, off by default |

Anything else on a routable address is a defect unless an inventory variable says otherwise
([ADR 0007](docs/adr/0007-host-firewall-scope.md)).

### Data network

- `onebox_data_network` (`onebox-data`) with the fixed `onebox_data_subnet` (`10.89.10.0/24` by
  default) is a Quadlet `.network` unit. Pick a subnet that overlaps none of the LAN, the pod and
  service CIDRs (`10.42.0.0/16`, `10.43.0.0/16` in k3s), podman's default network or any VPN
  range.
- Containers join with `podman_quadlet_networks: [onebox-data.network]` and address datastores
  by container name.
- Datastore containers have fixed addresses on that subnet: the Redis cluster gossips IPs, and
  pods reach the datastores through EndpointSlices that name those IPs.
- `datastores` owns superusers only. A service that needs a database creates its own role and
  database in its own role ([ADR 0011](docs/adr/0011-shared-datastores-app-owned-databases.md)).

### OIDC clients

| Variable | Meaning |
|---|---|
| `onebox_oidc_issuer` | Issuer URL every service trusts: `https://sso.<domain>` when `casdoor` is enabled, otherwise set it to your IdP |
| `onebox_oidc_clients` | One entry per relying party (`gitlab`, `argocd`, `openbao`): `title`, `redirect_uris` |
| `<name>_oidc_client_id`, `<name>_oidc_client_secret` | Secrets in `secrets.yml`; with Casdoor they are created by convergence, otherwise copied from your IdP |

Redirect URIs are derived from the hostnames below, so renaming a host updates the identity
provider and the service together.

### Shared hostnames and facts

| Variable | Default | Read by |
|---|---|---|
| `edge_portal_hostname` | `<domain>` | edge (portal) |
| `gitlab_hostname`, `gitlab_registry_hostname` | `gitlab.<domain>`, `registry.<domain>` | gitlab, runner, argocd, external-secrets |
| `casdoor_hostname` | `sso.<domain>` | casdoor, every OIDC client |
| `openbao_hostname` | `bao.<domain>` | openbao, external-secrets |
| `argocd_hostname` | `argocd.<domain>` | argocd, OIDC clients |
| `k3s_kubeconfig` | `/etc/rancher/k3s/k3s.yaml` | every role that talks to the cluster |
| `k3s_gateway_http_port` | `31080` | k3s-gateway, every vhost that routes into the cluster |
| `onebox_os_family` | from facts | every role with OS-specific values |
| `edge_bin`, `edge_config_dir`, `edge_confd_dir`, `edge_data_dir`, `edge_portal_dir`, `edge_admin_mode`, `edge_admin_socket` | see file | caddy_edge, caddy_vhost |

### OpenBao ↔ External Secrets

| Variable | Default | Meaning |
|---|---|---|
| `openbao_kv_mount` | `kv` | KV v2 mount holding workload secrets |
| `openbao_k8s_auth_mount` | `kubernetes` | Kubernetes auth method External Secrets logs in with |
| `openbao_eso_role` | `external-secrets` | Auth role bound to the operator's service account |
| `external_secrets_namespace` | `external-secrets` | Namespace of the operator |
| `external_secrets_service_account` | `external-secrets` | Service account OpenBao validates through TokenReview |

KV layout: `platform/registry/<registry>/<tenant>`, `platform/datastore/<engine>`,
`<tenant>/env/<tier>` ([ADR 0017](docs/adr/0017-openbao-and-external-secrets.md)).

### Calls from pods to platform vhosts

External Secrets (to OpenBao) and Argo CD (to the OIDC issuer and to GitLab) leave the cluster
and come back through the edge. They arrive with pod-network source addresses, so:

- the pod CIDR must be allowed on those vhosts, or they receive 403 — it is, automatically:
  `onebox_internal_cidrs` = `onebox_lan_cidrs` + the pod network (when k3s runs and
  `k3s_pods_trusted_by_edge`) + the tailnet (when tailscale runs) + `onebox_internal_extra_cidrs`;
- the names must resolve inside the cluster (the wildcard record does this when the cluster's
  upstream resolver sees it);
- with `edge_tls_mode: internal` or a private CA in `files` mode, in-cluster clients must be
  given that CA.

### Render mode

`onebox_render_only`, `onebox_root`, `onebox_owner` and `onebox_group` let every role's
`tasks/render.yml` write its files into a scratch directory for testing
([ADR 0024](docs/adr/0024-render-mode-static-testing.md)).

## Providers

Everything environment-specific is a variable chosen in the inventory, never a fork of a role.

| Dimension | Variable | Choices | Notes |
|---|---|---|---|
| OS family | `onebox_os_family` (from facts) | `RedHat`: Rocky, AlmaLinux, RHEL 9 and 10 · `Debian`: Debian 13, Ubuntu 24.04+ | Package lists and unit names in `roles/common/vars/<family>.yml` (`sshd` vs `ssh`; Ubuntu's socket-activated `ssh.socket`; `semanage` and `restorecon` on SELinux hosts; `uidmap` and `passt` for rootless podman on Debian) |
| Host firewall | `common_firewall_backend` | `firewalld`, `none` | `none` for cloud security groups or an external firewall |
| TLS | `edge_tls_mode` | `acme_dns`, `acme_http`, `internal`, `files` | Wildcard site addresses (`*.apps.<domain>`) need `acme_dns`, `internal` or `files`; `acme_http` needs inbound 80/443 from the CA |
| DNS-01 provider | `edge_dns_provider`, `edge_dns_options`, `edge_dns_env`, `edge_dns_catalog_extra` | `route53`, `cloudflare`, `rfc2136`, or your own catalog entry | Each entry names the Go module, the Caddy module ID and the secret environment variables |
| ACME directory | `edge_acme_ca` | public CA, staging, private ACME | e.g. a private step-ca |
| Edge admin API | `edge_admin_mode` | `unix`, `off` | `off` turns every config change into a restart |
| Identity | `onebox_oidc_issuer` | bundled Casdoor, or any OIDC IdP | Keycloak, Entra ID, Google Workspace, … |
| Admin SSH port | `common_admin_ssh_port` | `22` or another port | Move it when GitLab should own 22 |
| Remote access | `tailscale` component | on / off | |

Test scenarios that exercise these branches (`tests/scenarios/`):

| Scenario | OS family | Firewall | TLS | Other branches |
|---|---|---|---|---|
| `redhat-full` | RedHat | firewalld | `internal` | every component, admin SSH on 2222, smartd |
| `debian-minimal` | Debian | none | `acme_dns` / cloudflare | edge + datastores only |
| `edge-acmehttp-ubuntu` | Debian (Ubuntu) | none | `acme_http` | public by default |
| `edge-files-redhat` | RedHat | firewalld | `files` | admin API off, edge-owned static and redirect sites |
| `edge-rfc2136-debian` | Debian | firewalld | `acme_dns` / rfc2136 | staging ACME directory |

## Deployment layering

```
make <target>                     the only human interface (ADR 0003)
  └─ deploy.sh <command>          bash only; resolves inventories/<env>; installs ansible-core
       └─ ansible-playbook site.yml -i inventories/<env> [--tags <component>] [--check --diff]
            preflight (always) → common → storage → operators → tailscale → edge → datastores →
            k3s → casdoor → openbao → gitlab → gitlab-runner → k3s-gateway →
            external-secrets → argocd → argo-rollouts
```

- **Environments:** `make init ENV=<name>` copies `inventories/example`. `deploy.sh` picks the
  only environment automatically, or the one named by `ENV=`.
- **One play per component**, tagged with the component name; a component that is not listed
  is skipped. Services with a vhost run `caddy_vhost` in the same play, after the service.
- **Preflight runs first, tagged `always`:** ansible-core version, known components and their
  dependencies, supported OS, then each selected component's own `preflight.yml` (secrets filled,
  variables valid). With `make <component>`, only that component's checks run, so one service can
  be converged while another's secrets are still placeholders.
- **Facts are gathered once** in the preflight play and reused.
- **Dry run:** `make check [TAGS=a,b]`. It shows real diffs for templates, files, packages and
  units; `command` tasks are skipped, so runtime behaviour is verified after the first real run.
- **Secrets:** `inventories/<env>/group_vars/onebox/secrets.yml`, optionally vault-encrypted
  (`VAULT=1`); `ASK_BECOME=1` prompts for the sudo password when not running as root.
- **Static tests:** `make test` → `tests/run.sh` → lint, syntax check, `tests/render.yml` per
  scenario, validators (Quadlet dry-run, `caddy validate` with the built binary, kubeconform).

## Adding a component

1. **Decide the shape.** A container on the host goes through `podman_quadlet`; a cluster
   workload is a `HelmChart` or manifest rendered into
   `/var/lib/rancher/k3s/server/manifests/onebox-<name>.yaml`. If the choice is a new decision
   (not covered by an ADR), write the ADR first.
2. **Create `roles/<role>/`** following [CLAUDE.md §3](CLAUDE.md): `defaults/main.yml` (every
   variable prefixed and documented), `tasks/main.yml` (includes `render.yml`),
   `tasks/render.yml` (file-writing tasks only, paths under `{{ onebox_root }}`),
   `tasks/preflight.yml` (assert required variables and secrets; loop over variable *names*;
   placeholders start with `CHANGE-ME`), `handlers/main.yml` (every handler guarded with
   `when: not onebox_render_only`), and a `README.md` explaining variables, contracts,
   operations and pitfalls.
3. **Publish on `127.0.0.1` only;** pass secret environment through `podman_quadlet_secrets`.
   OS-specific values go in `vars/<family>.yml` or derive from `onebox_os_family`. Pin images and
   downloads with checksums or digests.
4. **If it serves HTTPS,** expose `<role>_vhost_entries` and add a play to `site.yml` that runs the
   role and then `caddy_vhost`; add the component to `_vhost_components` in `tests/render.yml`.
5. **Register the component:** an entry in `onebox_component_requires`, the play and tag in
   `site.yml`, the target in the `Makefile`'s `COMPONENTS`, and a mapping in
   `roles/preflight/tasks/main.yml` and `tests/render.yml` if the role name differs from the
   component name.
6. **Secrets:** add every key with a `CHANGE-ME…` placeholder to `secrets.example.yml`.
7. **Shared values:** only values that another role reads go into `group_vars/all/onebox.yml`;
   never redeclare them in role defaults.
8. **Operations:** add `<component>-status`, `-logs`, `-backup`, … to `deploy.sh` and the
   `Makefile` as soon as you would ask someone to run a command twice.
9. **Tests:** cover each provider branch the role adds in a scenario under `tests/scenarios/`,
   then run `make test`.

## Decision records

| Area | Records |
|---|---|
| Foundations | [0001 one host, one repository](docs/adr/0001-one-host-per-environment-one-repository.md) · [0002 ansible-core only](docs/adr/0002-ansible-core-only.md) · [0003 make interface](docs/adr/0003-make-is-the-operator-interface.md) · [0009 guarded irreversible changes](docs/adr/0009-guarded-irreversible-changes.md) |
| Edge and network | [0004 host-native edge](docs/adr/0004-host-native-edge-proxy.md) · [0005 certificates and TLS modes](docs/adr/0005-certificates-dns01-and-tls-modes.md) · [0006 internal-only by default](docs/adr/0006-internal-only-by-default.md) · [0007 firewall scope](docs/adr/0007-host-firewall-scope.md) · [0008 port 22 for git](docs/adr/0008-git-over-ssh-owns-port-22.md) · [0020 remote access](docs/adr/0020-remote-access-mesh-vpn.md) |
| Host services and data | [0010 podman and Quadlet](docs/adr/0010-podman-quadlet-services.md) · [0011 shared datastores](docs/adr/0011-shared-datastores-app-owned-databases.md) · [0012 datastore reachability](docs/adr/0012-datastore-reachability.md) · [0013 operator accounts](docs/adr/0013-personal-operator-accounts.md) |
| Cluster and delivery | [0014 single-node k3s](docs/adr/0014-single-node-k3s.md) · [0015 cluster gateway](docs/adr/0015-loopback-cluster-gateway.md) · [0016 GitOps](docs/adr/0016-gitops-central-repository.md) · [0019 CI runner](docs/adr/0019-ci-runner-on-the-host.md) · [0026 admission policy (proposed)](docs/adr/0026-admission-policy.md) |
| Identity and secrets | [0017 OpenBao and External Secrets](docs/adr/0017-openbao-and-external-secrets.md) · [0018 one OIDC issuer](docs/adr/0018-one-oidc-issuer.md) · [0021 secrets handling](docs/adr/0021-secrets-handling.md) · [0025 off-host copies (proposed)](docs/adr/0025-off-host-copies.md) |
| Engineering practice | [0022 reported success, did nothing](docs/adr/0022-reported-success-did-nothing.md) · [0023 version pinning](docs/adr/0023-version-pinning.md) · [0024 render-mode testing](docs/adr/0024-render-mode-static-testing.md) |
