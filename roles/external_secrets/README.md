# roles/external_secrets — OpenBao → Kubernetes Secrets

External Secrets Operator plus the one `ClusterSecretStore` that tells every namespace how to
reach OpenBao. Applications declare in their GitOps repositories *which* keys they need
(`ExternalSecret`); the platform owns the store, the values and the policies. Why OpenBao on
the host, why Kubernetes auth, why pull secrets by namespace label:
[ADR 0017](../../docs/adr/0017-openbao-and-external-secrets.md).

Component: `external-secrets` (needs `k3s`, `openbao`).

## What it deploys

| File (k3s manifests dir) | Objects |
|---|---|
| `onebox-external-secrets.yaml` | Namespace, the OpenBao identity ServiceAccount, its `system:auth-delegator` binding, the HelmChart |
| `onebox-external-secrets-store.yaml` | `ClusterSecretStore` + one `ClusterExternalSecret` per pull-secret tenant |

Two files because k3s rejects a whole file when one of its kinds does not exist yet: the store
needs the chart's CRDs and its admission webhook. k3s retries the second file every 15 s; the
converge waits for both (`roles/k3s/tasks/wait_addon.yml`) and then for the store to be
**Ready**, printing the store's own message and a cause table if it is not.

The chart archive is pinned by version and the digest from the repository index and served by
k3s (same mechanism as the gateway). `failurePolicy: abort` and
`crds.annotations: helm.sh/resource-policy: keep`: uninstalling this chart would otherwise delete
its CRDs, every `ExternalSecret`, and — through owner references — every Secret they produced,
pull secrets included.

## The contract with roles/openbao

All names come from `group_vars/all/onebox.yml`, so both sides read the same values:

| Variable | Default | Used as |
|---|---|---|
| `openbao_kv_mount` | `kv` | `spec.provider.vault.path` (KV v2) |
| `openbao_k8s_auth_mount` | `kubernetes` | `auth.kubernetes.mountPath` |
| `openbao_eso_role` | `external-secrets` | `auth.kubernetes.role` |
| `external_secrets_namespace` / `external_secrets_service_account` | `external-secrets` / `external-secrets` | the identity OpenBao's role binds (`bound_service_account_names/-namespaces`) |

What the OpenBao side needs to configure for this to work:

- the kubernetes auth mount with `kubernetes_host` = the API server as seen from the OpenBao
  container (`https://<host address>:6443`), `kubernetes_ca_cert` =
  `/var/lib/rancher/k3s/server/tls/server-ca.crt`, and **no** `token_reviewer_jwt` — OpenBao
  then reviews the client's own token, which is why that account has `system:auth-delegator`;
- the role above, with a read policy on the paths workloads may use (and on
  `platform/registry/*` when pull secrets are enabled).

The identity account (`external-secrets`) is deliberately **not** the controller's account
(`external_secrets_controller_service_account`, `external-secrets-controller`): the controller's
token can write Secrets cluster-wide; the identity only proves who is asking. External Secrets
mints short-lived tokens for it (TokenRequest) — there is no static credential in the cluster or
in OpenBao.

## Reaching OpenBao from a pod

`https://{{ openbao_hostname }}` through the edge. Three things must hold, and the converge
names the one that fails:

1. **The edge lets the pod in.** OpenBao's vhost is internal-only; a pod's packets keep the pod
   address; `k3s_cluster_cidr` is part of `onebox_internal_cidrs` automatically (unless
   `k3s_pods_trusted_by_edge: false`).
   Symptom otherwise: `403`.
2. **Pods resolve the name.** CoreDNS forwards to the host's resolvers; if the name only resolves
   on the host, pin it with `k3s_coredns_hosts`. Symptom: `no such host`.
3. **The certificate is trusted.** Public ACME certificates need nothing. With
   `edge_tls_mode: internal` (Caddy's CA) or a private CA in `files` mode, set
   `external_secrets_ca_file` (default `onebox_edge_ca_file`) to the CA's PEM on the host —
   for the internal CA that is `<edge data dir>/.local/share/caddy/pki/authorities/local/root.crt`.
   The role reads it at converge time and embeds it as `caBundle`. Symptom: `x509`.

## Using it from a workload

```yaml
apiVersion: external-secrets.io/v1          # v1 only: this chart does not serve v1beta1
kind: ExternalSecret
metadata:
  name: demo-api
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: demo-api-secrets
  data:
    - secretKey: DATABASE_PASSWORD
      remoteRef:
        key: demo/env/dev                    # kv/demo/env/dev (path layout: ADR 0017)
        property: database_password
```

`target.template` builds composite values (DSNs, config files) — keep that in the workload's
declaration, not in the platform.

## Image pull secrets

```yaml
external_secrets_registry_pull_enabled: true
external_secrets_registry_pull_tenants:
  - name: demo                    # registry: external_secrets_registry_pull_default_registry
                                  # (the GitLab registry when gitlab is a component), credential
                                  # at kv/platform/registry/internal/demo {username, password}
```

Every namespace labelled `onebox/registry-pull: demo` gets a `kubernetes.io/dockerconfigjson`
Secret `registry-pull` — namespaces created later too, no platform run. Workloads reference it
themselves (`imagePullSecrets: [{name: registry-pull}]`); the platform keeps no list of tenant
namespaces and patches no service accounts. One rule per tenant, so a tenant's namespaces never
receive another tenant's credential. Several registries per tenant are one `auths` table.

- **Fail-closed:** if any listed credential is missing in OpenBao, the Secret is not produced at
  all — do not list a registry before its credential exists.
- **No adoption:** `creationPolicy: Owner` does not take over an existing Secret of the same name;
  delete a hand-made `registry-pull` first, or the ExternalSecret stays in `SecretSyncedError`.
- **The credential** is a group deploy token with `read_registry` only, never a personal or
  administrator token: every pod in a labelled namespace can read it. Do not name the token
  `gitlab-deploy-token` (GitLab injects that name into every CI job).
- **Caches hide mistakes:** with `IfNotPresent` and an image already on the node, a wrong pull
  secret goes unnoticed until an unrelated change reschedules the pod. Check what `image:`
  really points at before changing which registry a pull secret serves.

## Operations

```bash
sudo make external-secrets
kubectl get clustersecretstore openbao                      # READY True
kubectl get clusterexternalsecret                           # one per pull-secret tenant
kubectl -n <ns> get externalsecret                          # SecretSynced per workload
kubectl -n external-secrets logs deploy/external-secrets    # login and sync errors
```

A Ready store proves login, not authorisation: the end-to-end proof is writing a value into
OpenBao and reading it back through an `ExternalSecret` (suggested target `openbao-test`).

## Known gaps

- **One store, one OpenBao role:** every namespace can reference the store, and the store can read
  whatever the role's policy allows — a tenant can request another tenant's path. Tenant
  isolation needs one store per tenant (`spec.conditions` with a namespace selector) backed by a
  per-tenant OpenBao role limited to `<tenant>/*`. Until then, keep tenants that must not read
  each other's secrets on separate platforms.
- **Pull secrets in new namespaces depend on External Secrets and OpenBao.** Existing Secrets
  survive an outage (External Secrets does not delete what it created).
