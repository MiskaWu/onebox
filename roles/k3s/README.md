# roles/k3s — single-node Kubernetes

Installs one k3s server node: the workload runtime next to the podman services. Why k3s, why
one node and why no bundled ingress: [ADR 0014](../../docs/adr/0014-single-node-k3s.md).

Component: `k3s` (no dependencies). The cluster roles that run on it — `k3s_gateway`,
`external_secrets`, `argocd`, `argo_rollouts` — only write manifests into its auto-deploy
directory; nothing else on the host talks to the API server.

## What it does

| Step | Detail |
|---|---|
| Prerequisites | asserts cgroup v2; refuses a version change of more than one Kubernetes minor (or a minor downgrade); creates `k3s_admin_group` and adds the existing `k3s_admin_users`; with firewalld running, trusts the pod and service CIDRs (runtime + permanent, no reload) |
| Configuration | `/etc/rancher/k3s/config.yaml` (from `_k3s_config` = role settings ∪ `k3s_extra_config`), `registries.yaml` when a registry is configured |
| Software | k3s-selinux (RHEL family, pinned RPM + sha256), the k3s binary (pinned release + sha256), the systemd unit via upstream's installer pinned to the same tag |
| Start + verify | `systemctl start k3s`, waits for `/readyz` and node `Ready`, checks the kubeconfig really is `root:<group> 0640` |
| Manifests | `onebox-coredns-custom.yaml` (CoreDNS overrides, see below) |

### Install method and why

The binary is downloaded by Ansible from the GitHub release and verified against the sha256
recorded in `k3s_binary_sha256` (copied from the release's `sha256sum-<arch>.txt`): converges
are offline once the file is in place, and a re-tagged release fails loudly.

The upstream `install.sh` is still used — pinned to the same git tag and its own sha256 — but
with `INSTALL_K3S_SKIP_DOWNLOAD=true`, `SKIP_SELINUX_RPM`, `SKIP_ENABLE` and `SKIP_START`. It
only writes the systemd unit, the `kubectl`/`crictl`/`ctr` links, `k3s-killall.sh` and
`k3s-uninstall.sh`. Rewriting those would mean owning a copy of upstream's knowledge of every
mount, network interface and iptables chain k3s creates; keeping the installer for exactly
that keeps uninstall correct for each release. It runs only on a first install or a version
change, from a staging directory, and is deleted afterwards (ADR 0014).

`INSTALL_K3S_BIN_DIR` is pinned: without it the installer silently falls back to `/opt/bin`
when `/usr/local/bin` is not writable, and every path in the platform would be wrong.

The SELinux policy is a pinned RPM installed with `dnf`, not the installer's
`rpm.rancher.io` repository: no third-party repository stays configured on the host, and the
package is the one whose checksum is in the repo. After installing it, `restorecon` gives the
binary its `container_runtime_exec_t` label. `selinux: true` in `config.yaml` (default on the
RHEL family) makes containerd label containers.

## Variables

All in [defaults/main.yml](defaults/main.yml). The ones you are most likely to touch:

| Variable | Default | Meaning |
|---|---|---|
| `k3s_version`, `k3s_binary_sha256`, `k3s_install_script_sha256` | v1.36.5+k3s1 | the three pins that move together |
| `k3s_admin_group` / `k3s_admin_users` | `k3s-admin` / the operators | who can run `kubectl` without sudo (= cluster-admin) |
| `k3s_cluster_cidr` / `k3s_service_cidr` | 10.42.0.0/16 / 10.43.0.0/16 | fixed for the life of the cluster |
| `k3s_service_node_port_range` | 30000-30999 | narrowed: 31000+ stays free for host-network listeners |
| `k3s_tls_san` | host IP, `k3s.<domain>` | extra API certificate names |
| `k3s_disable` | traefik, servicelb | must keep both; add `onebox-<addon>` names to uninstall an AddOn |
| `k3s_extra_config` | `{}` | any other `k3s server` flag |
| `k3s_registry_enabled` | `'gitlab' in onebox_components` | write `registries.yaml` for `gitlab_registry_hostname` |
| `k3s_registry_ca_file` / `k3s_registry_username` | `onebox_edge_ca_file` / "" | containerd → GitLab registry trust and optional node-wide credentials |
| `k3s_registries_extra` | `{}` | more registries (endpoint, CA, no credentials) |
| `k3s_coredns_hosts` | `{}` | hostnames pinned in cluster DNS |

Secret (only when `k3s_registry_username` is set): `k3s_registry_password`.

## Contracts with other roles

- **Kubeconfig:** `k3s_kubeconfig` (group_vars) — readable by `k3s_admin_group`.
- **Auto-deploy directory:** `/var/lib/rancher/k3s/server/manifests/onebox-<name>.yaml`. k3s
  applies a file when it changes (polling every 15 s), tracks it as an `AddOn` named after the
  file, and **prunes objects that disappear from a file** — but **deleting a whole file deletes
  nothing**. Optional objects therefore live in files that are always rendered.
- **`tasks/wait_addon.yml`:** other roles include it after writing a manifest. k3s writes the
  file's sha256 into `AddOn.spec.checksum` only after *every* object in it was applied, so the
  helper waits for that equality and, on timeout, prints the AddOn's events. A manifest the API
  server rejects therefore fails the converge instead of passing silently.
- **Pods count as internal at the edge:** pods reach the OIDC issuer, OpenBao and Git through
  the edge with their pod address as the client address, and those vhosts are internal-only.
  `k3s_cluster_cidr` joins `onebox_internal_cidrs` automatically while
  `k3s_pods_trusted_by_edge` is true (ADR 0006, 0017).
- **NodePort range vs. the gateway port:** kube-proxy DNATs NodePorts on *every* local address,
  127.0.0.1 included. A Service that happened to receive NodePort 31080 would capture the
  edge → gateway traffic. The range is narrowed to 30000-30999 and the preflight checks that
  `k3s_gateway_http_port` lies outside it.

## Cluster DNS overrides

CoreDNS forwards to the host's resolvers. If platform hostnames resolve only on the host (a lab
with `/etc/hosts`, a split DNS that pods do not use), pin them:

```yaml
k3s_coredns_hosts:
  "{{ openbao_hostname }}": "{{ onebox_host_ip }}"
  "{{ onebox_oidc_issuer | urlsplit('hostname') }}": "{{ onebox_host_ip }}"
```

Each name becomes its own server block in the `coredns-custom` ConfigMap (k3s' CoreDNS imports
`*.server` keys from it), so other names in the zone are unaffected. CoreDNS does not reload
imported files by itself; the role restarts it after k3s applied the change. The answers are
the same addresses public DNS returns — this is not split-horizon DNS, only independence from
the upstream resolvers.

## Operations

```bash
sudo make k3s                       # converge
kubectl get nodes                   # as a member of k3s_admin_group
ssh -L 6443:127.0.0.1:6443 you@host # remote kubectl: the API is not opened to the LAN
```

- **Upgrade:** bump the three pins to the next minor's release, `make check TAGS=k3s`, then
  `make k3s`. One minor at a time; the role refuses bigger steps.
- **Grant access:** add the account to `operators_admins` (or `k3s_admin_users`) and converge;
  the person logs in again (`newgrp k3s-admin` for the current shell). Revoke by removing them
  from the group (`gpasswd -d <user> k3s-admin`) — the role only appends.
- **Remove a cluster component:** add its AddOn name to `k3s_disable` (for example
  `onebox-argo-rollouts`) and run `make k3s`. k3s deletes the AddOn's objects — for a HelmChart
  that runs `helm uninstall` — and the file. Then drop the component from `onebox_components`
  and the name from `k3s_disable` again.
- **Uninstall k3s:** `playbooks/k3s-uninstall.yml` previews what would be destroyed; with
  `-e k3s_uninstall_confirm=<env>` it runs upstream's `k3s-uninstall.sh` (ADR 0009). It deletes
  the data directory — every workload and volume on local-path storage.

## Pitfalls (and why the role looks the way it does)

- **CIDRs are forever.** They are written into the datastore at first start; the preflight
  checks overlaps with podman's ranges (`k3s_reserved_cidrs`) before that can happen.
- **Group before first start.** k3s chowns the kubeconfig to `write-kubeconfig-group` when it
  writes it; the group must exist already. Group changes need a new login.
- **Directory traversal.** `/etc/rancher` and `/etc/rancher/k3s` are `root:<group> 0750`,
  `config.yaml.d` exists and is group-readable: otherwise members' `kubectl` cannot reach the
  kubeconfig or prints permission warnings while scanning the drop-in directory.
- **Secrets encryption** is cheap only on a new cluster. On an existing one, enabling it
  encrypts new writes; run `k3s secrets-encrypt reencrypt` for the rest.
- **API port 6443** listens on all addresses (pods reach it through the node IP). It is a
  host-native socket, so firewalld does protect it (ADR 0007); with
  `common_firewall_backend: none` it relies on client-certificate authentication alone.
- **NodePorts** are DNAT'd and bypass the host firewall entirely; nothing in the platform uses
  them. Avoid them in workloads (ADR 0015, ADR 0026).
