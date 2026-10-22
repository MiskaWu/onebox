# Architecture decision records

Why onebox is built the way it is. Each record states the context, the decision, what it
costs, what was rejected, and — most importantly — **when to revisit it**. Read the relevant
record before proposing "should we switch to X?": if none of its revisit conditions holds, the
question has already been answered.

| # | Title | Status | Summary |
|---|---|---|---|
| [0001](0001-one-host-per-environment-one-repository.md) | One host per environment, one repository | Accepted | Environment boundary is a separate instance; roles decouple services; every value is declared once. |
| [0002](0002-ansible-core-only.md) | Pure Ansible on ansible-core | Accepted | No Terraform/Pulumi, no Galaxy collections; stateless runs and a zero-dependency bootstrap. |
| [0003](0003-make-is-the-operator-interface.md) | `make` is the only operator interface | Accepted | make → deploy.sh → ansible; one verb per meaning; guards for TAGS, root and unknown commands. |
| [0004](0004-host-native-edge-proxy.md) | Host-native edge proxy | Accepted | Caddy owns 80/443 under systemd, built reproducibly; one drop-in contract; admin API on a unix socket. |
| [0005](0005-certificates-dns01-and-tls-modes.md) | Certificates and TLS modes | Accepted | DNS-01 for LAN-only names; TLS mode and DNS provider are catalog choices; only the edge speaks ACME. |
| [0006](0006-internal-only-by-default.md) | Internal-only by default | Accepted | Every vhost answers 403 outside the LAN unless its entry opens it; workloads live under `*.apps`. |
| [0007](0007-host-firewall-scope.md) | Host firewall scope | Accepted | Published ports and NodePorts bypass INPUT rules — bind to loopback; re-apply container rules after reloads. |
| [0008](0008-git-over-ssh-owns-port-22.md) | git-over-SSH owns port 22 | Accepted | SSH has no SNI, so one IP's 22 serves one server: the forge gets it, admin sshd moves. |
| [0009](0009-guarded-irreversible-changes.md) | Guarded irreversible changes | Accepted | Prove the new path before removing the old; preview/confirm; protect lists; automate only the non-destructive. |
| [0010](0010-podman-quadlet-services.md) | Podman + Quadlet services | Accepted | Rootful Quadlet units, loopback publishing, podman secrets, pinned images without auto-update. |
| [0011](0011-shared-datastores-app-owned-databases.md) | Shared datastores | Accepted | Shared engines on a private network; apps create their own databases; dedicated DB as escape hatch. |
| [0012](0012-datastore-reachability.md) | Datastore reachability | Accepted | Pods use data-network IPs via selectorless Services; people use SSH tunnels; nothing on the LAN. |
| [0013](0013-personal-operator-accounts.md) | Personal operator accounts | Accepted | One account per person, sudo with a password, explicit two-stage offboarding, console-only break-glass. |
| [0014](0014-single-node-k3s.md) | Single-node k3s | Accepted | k3s with SQLite, bundled ingress and load balancer disabled, group-based admin access. |
| [0015](0015-loopback-cluster-gateway.md) | Loopback cluster gateway | Accepted | Own Traefik on hostNetwork bound to loopback, no Service; Ingress + Gateway API; non-HTTP opt-in. |
| [0016](0016-gitops-central-repository.md) | GitOps with Argo CD | Accepted | Central GitOps repo, environments as directories, gate on the CI bump, one AppProject per tenant. |
| [0017](0017-openbao-and-external-secrets.md) | OpenBao and External Secrets | Accepted | Host-side OpenBao with static auto-unseal; ESO via Kubernetes auth; pull secrets by namespace label. |
| [0018](0018-one-oidc-issuer.md) | One OIDC issuer | Accepted | All services trust one issuer (bundled Casdoor or any IdP); clients declared once and created by IaC. |
| [0019](0019-ci-runner-on-the-host.md) | CI runner on the host | Accepted | Shell executor + rootless podman with guardrails; default jobs go to the container runner. |
| [0020](0020-remote-access-mesh-vpn.md) | Remote access via mesh VPN | Accepted | Outbound-only Tailscale with Tailnet Lock instead of exposing services. |
| [0021](0021-secrets-handling.md) | Secrets handling rules | Accepted | `no_log` on tasks with secret arguments, never on asserts; loop over names, not values. |
| [0022](0022-reported-success-did-nothing.md) | "Reported success, did nothing" | Accepted | Verify every control from the data path; diagnostics must not swallow errors. |
| [0023](0023-version-pinning.md) | Version pinning | Accepted | Pin with checksums; bump by explicit criteria; tripwires on overridden upstream defaults. |
| [0024](0024-render-mode-static-testing.md) | Render-mode static testing | Accepted | Render every role per scenario and validate with Quadlet, `caddy validate` and kubeconform. |
| [0025](0025-off-host-copies.md) | Off-host copies | Proposed | Repository, encrypted secrets, unrecoverable keys and datastore dumps must exist off the host. |
| [0026](0026-admission-policy.md) | Admission policy | Proposed | Built-in CEL validation for host ports; a mutating policy engine only when its triggers fire. |

## Conventions

- File name `NNNN-kebab-title.md`; sections: Status, Context, Decision, Consequences (including
  the costs accepted), Alternatives considered, Revisit when.
- Status is **Accepted** or **Proposed**. A record is never deleted: when a decision changes,
  write a new record and mark the old one *Superseded by NNNN*.
- "Do not do X" decisions live here. Role READMEs explain *how* and link back to the record that
  explains *why* — a prohibition that only exists in one role's README is not read by someone
  planning a change elsewhere.
- Records describe decisions at the level of the platform; concrete variable names and defaults
  belong in each role's `defaults/main.yml` and `README.md`.
