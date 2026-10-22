# roles/argocd — the GitOps control plane

Argo CD, pinned and installed through a k3s `HelmChart`, behind the cluster gateway and the
edge, with single sign-on against the platform's issuer, RBAC from variables, one AppProject per
tenant and one app-of-apps root pointer per tenant. Delivery model, tenancy and the reasons
behind them: [ADR 0016](../../docs/adr/0016-gitops-central-repository.md); the EndpointSlice
exception: [ADR 0012](../../docs/adr/0012-datastore-reachability.md).

Component: `argocd` (needs `k3s`, `k3s-gateway`). A repository skeleton for tenants is in
[`examples/gitops/`](../../examples/gitops/).

**Boundary:** the platform provides a healthy Argo CD, the tenant boundaries and the root
pointers. What gets deployed lives in the tenants' GitOps repositories. Argo CD never deploys
the platform itself — the platform must be rebuildable while the cluster is down.

## What it deploys

| File (k3s manifests dir) | Objects |
|---|---|
| `onebox-argocd.yaml` (0600, no_log) | `Secret kube-system/argocd-onebox-values` (OIDC client, repository tokens) + `HelmChart argocd` |
| `onebox-argocd-tenants.yaml` | `AppProject platform-roots`, per tenant `AppProject <t>` + `Application <t>-root`, the locked `default` project |

The secret chart values go through `valuesSecrets`, so the `HelmChart` object — readable by
anyone allowed to list HelmCharts — carries no credential; Secrets are encrypted at rest (k3s
`secrets-encryption`). The second file needs the chart's CRDs; k3s retries it until they exist,
and the converge waits for both and then for `GET /healthz` through the gateway with the real
`Host` header.

## Settings that matter, and why

- **`server.insecure: true`** — TLS ends at the edge; otherwise the server redirects to HTTPS and
  loops behind it.
- **Dex disabled** — the platform's issuer is the only broker (ADR 0018).
- **Ingress, not HTTPRoute,** for the UI: the gateway serves both; using the chart's Ingress keeps
  the Ingress provider exercised by a real consumer (ADR 0015).
- **`application.resourceTrackingMethod: annotation`, explicitly**, and **`resource.exclusions`
  replaced** by a copy of the chart's list that no longer excludes
  `discovery.k8s.io/EndpointSlice`. An excluded kind does not exist for Argo CD — an EndpointSlice
  in Git would be skipped while the app shows Synced and Healthy. With *label* tracking the
  exception would be dangerous: slices generated for every Service inherit its labels and would
  be pruned and recreated in a loop. Core `Endpoints` stays excluded.
- **Tripwire `argocd_exclusions_reviewed_for`** — our copy replaces the chart's list, so upstream
  changes never reach us by themselves. The preflight refuses a chart version other than the one
  last compared. On a bump: diff `configs.cm."resource.exclusions"` of the new chart against
  `_argocd_resource_exclusions` (vars/main.yml), carry upstream changes over, update the variable.
  It is a reminder, not a check — it deliberately does not fetch upstream during converge.
- **`failurePolicy: abort`** — a failed upgrade keeps the old release instead of
  uninstall-and-reinstall.
- **ApplicationSet controller** cannot be switched off in this chart (its template has no
  condition); writing a non-existent `enabled: false` would only look like it worked.

## Sign-in

| Path | How |
|---|---|
| SSO | button on the login page; client `argocd` from `onebox_oidc_clients` (redirect `https://<argocd_hostname>/auth/callback`), secrets `argocd_oidc_client_id` / `argocd_oidc_client_secret` |
| local `admin` | break-glass; initial password in `argocd/argocd-initial-admin-secret` |

The admin password is never put into secrets: the field wants a bcrypt hash, bcrypt salts
differ on every render, and the manifest would change (and restart the server) on every
converge. Change it in the UI (User Info → Update Password), then delete the initial secret.

**Turning the local admin off** is a three-step cutover (ADR 0009): list yourself in
`argocd_rbac_admins` and converge → sign in through SSO and **sync an application** (seeing the
UI proves nothing about your role) → set `argocd_local_admin_enabled: false` and converge. The
preflight refuses `false` while no SSO admin is declared. Setting it back to `true` is the
break-glass path and needs no SSO.

With `edge_tls_mode: internal` (or a private CA in `files` mode) set `argocd_ca_file` (default
`onebox_edge_ca_file`): it becomes the OIDC `rootCA` and the TLS certificate for every Git host
of the tenant repositories and credential templates. Pods reach the issuer and Git through the
edge, so the pod CIDR must be in `onebox_lan_cidrs` (roles/k3s checks it).

## RBAC

```yaml
argocd_rbac_default_role: role:readonly     # everyone signed in; "" = nothing
argocd_rbac_admins: [platform-admins, alice@example.com]
argocd_rbac_readers: []                     # role:readonly, for when the default is ""
argocd_rbac_syncers:
  - {subject: demo-developers, tenant: demo}   # read-only + sync on demo/*
```

Subjects are OIDC group names or e-mails (`scopes: [groups, email]`), matched literally. Grant
only to people who have signed in once: an allowlisted e-mail without an account can be claimed
through self-sign-up on some identity providers (ADR 0018). Prefer groups when the list grows.
Symptom of a grant that does not match: "can sign in, Sync is greyed out" — the server log shows
the subject Argo CD actually saw.

## Tenants

```yaml
argocd_tenants:
  - name: demo                                             # ≤12 lowercase letters/digits
    repo: https://gitlab.dev.example.com/demo/gitops.git   # watched path: applications/
argocd_repo_credentials:
  - name: demo-gitops
    url: https://gitlab.dev.example.com/demo/gitops.git    # prefix match
    username: argocd-demo                                  # deploy token, read_repository only
    password_var: argocd_repo_demo_gitops_token            # secrets.yml key (not the value)
```

Each tenant yields `AppProject demo` (sources: its repositories; destinations: `demo-*`;
cluster-scoped kinds: Namespace only), `Application demo-root` in the platform-owned project
`platform-roots` (which may only create Applications in the `argocd` namespace — a tenant with
that right could edit everyone's subscriptions), and `role:demo-syncer`. Adding a tenant is one
entry; adding an environment is a file in the tenant's `applications/` directory.

- **`default` is locked** (`argocd_lock_default_project: true`): empty sources and destinations
  and an *explicit* empty cluster whitelist — Argo CD creates `default` with `*/*`, and applying
  a manifest leaves undeclared fields alone. When migrating existing Applications off `default`:
  unlock → create projects → move the Applications → lock. Skipped steps show up as "project not
  found / not permitted".
- **Root pointers have no `resources-finalizer`:** k3s prunes objects that disappear from a
  manifest, so removing a tenant from the list deletes its root — with the finalizer that would
  cascade into every workload of the tenant. Without it, only the pointer goes.
- **`prune` and `selfHeal` are off** on the roots (and should be on children at first): a change
  Argo CD newly recognises is detected but not applied until a manual sync, while
  `.status.operationState` still shows the previous success (ADR 0022). Ask Argo CD whether it
  knows an object at all with `.status.resources`, not whether the app is Synced.
- **Known gap:** child Applications are written by the tenant and choose their own `project`.
  A tenant can therefore reference another tenant's project — and through it deploy that
  tenant's repositories into that tenant's namespaces. Hard isolation needs Argo CD's
  "applications in any namespace" with per-tenant source namespaces.

## Operations

```bash
sudo make argocd
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
kubectl -n argocd get applications,appprojects
kubectl -n argocd logs deploy/argocd-server | grep -i -e oidc -e rbac     # sign-in problems
kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.resource\.exclusions}'   # live exclusions
```

First install takes minutes (several images); the converge waits up to
`argocd_ready_timeout`.
