# GitOps repository skeleton

A starting point for a tenant's GitOps repository on a onebox platform: copy this directory into
a new repository (one per tenant, separate from the source repositories), replace `demo` and
`dev.example.com`, and point the platform at it. The platform never deploys anything from here
itself — Argo CD does, within the tenant's boundary. Why the repository looks like this:
[ADR 0016](../../docs/adr/0016-gitops-central-repository.md).

Every manifest here passes `kubeconform -strict` (see [Validate](#validate)).

## Layout

```
applications/                  watched by the tenant's root pointer: one file = one Application
  demo-env-dev.yaml            the dev environment itself (envs/dev)
  demo-api-dev.yaml            HTTP service                 (apps/demo-api/overlays/dev)
  demo-api-bluegreen-dev.yaml  same service, blue/green     (apps/demo-api-bluegreen/overlays/dev)
  demo-mqtt-dev.yaml           MQTT: WebSocket + raw TCP    (apps/demo-mqtt/overlays/dev)
envs/
  dev/                         Namespace (with the platform's labels) + LimitRange
  branch/                      template for short-lived merge-request environments (+ quota)
apps/<service>/
  base/                        environment-neutral manifests, image without tag
  overlays/<env>/              namespace, image tag, environment hostnames
bootstrap/                     reference copies of what the platform renders — do not apply
```

**Environments are directories**, not branches or repositories: promoting to another
environment is a reviewable diff of `overlays/<env>`, never a merge between long-lived branches.

## Names

| Thing | Pattern | Example |
|---|---|---|
| tenant | ≤12 lowercase letters/digits | `demo` |
| namespace | `<tenant>-<env>` | `demo-dev`, `demo-mr42` |
| Application | `<tenant>-<component>-<env>` | `demo-api-dev` |
| hostname | `<tenant>-<service>[-<env>].apps.<domain>` — one label under `apps.` | `demo-api.apps.dev.example.com` |
| env token | `[a-z0-9]+`, branch environments `mr<iid>` | `dev`, `mr42` |

Flat names (`gitlab.`, `argocd.` …) belong to the platform. Everything under `*.apps.<domain>`
reaches the cluster without any platform change and is covered by the wildcard certificate —
but only **one** label deep: `demo-api.apps…` works, `api.demo.apps…` does not.

## What the platform provides (and what it needs from you)

In the platform's inventory, once per tenant:

```yaml
argocd_tenants:
  - name: demo
    repo: https://gitlab.dev.example.com/demo/gitops.git      # this repository
argocd_repo_credentials:
  - name: demo-gitops
    url: https://gitlab.dev.example.com/demo/gitops.git
    username: argocd-demo                                     # deploy token, read_repository
    password_var: argocd_repo_demo_gitops_token               # its value lives in secrets.yml
argocd_rbac_syncers:
  - {subject: demo-developers, tenant: demo}                  # who may press Sync
external_secrets_registry_pull_tenants:
  - name: demo                                                # pull secret for demo-* namespaces
k3s_gateway_tcp_entrypoints:                                  # only for the raw TCP example
  - {name: demo-mqtt, port: 1883}
```

That yields the AppProject `demo` (this repository only, `demo-*` namespaces, Namespace as the
only cluster-scoped kind), the root pointer `demo-root` watching `applications/`
([bootstrap/](bootstrap/) shows both), the `registry-pull` Secret in every namespace labelled
`onebox/registry-pull: demo`, the ClusterSecretStore `openbao`, and the Gateway `gateway/onebox`.

## A deployment, end to end

1. CI builds the image and pushes it with an immutable tag (environment prefix + commit SHA).
2. A manual `bump-dev` job in CI changes `newTag` in `apps/<service>/overlays/dev` and commits.
   **That commit is the deployment** — review, audit and `git revert` all work on it.
3. Argo CD notices the change and applies it (`automated`, without `prune` and `selfHeal`).
4. Blue/green only: the new version waits on the preview hostname until someone runs
   `kubectl argo rollouts promote`. Deploying is automatic; switching traffic is a decision.

`prune: false` leaves hash-suffixed ConfigMaps behind and the app OutOfSync — not a failure.
`selfHeal: false` means a change Argo CD only *recognises* (no new commit) is not applied until a
manual sync, while the status still shows the previous successful sync. To know whether Argo CD
manages an object at all, look at the Application's `.status.resources`, not at "Synced".

## The examples

- **demo-api** — Deployment, ClusterIP Service, `HTTPRoute` on `gateway/onebox`, an
  `ExternalSecret` reading `kv/demo/env/dev` through the platform's `ClusterSecretStore`, and a
  datastore address: a selectorless Service plus an EndpointSlice pointing at the datastore's
  fixed address on the host's data network, so the DSN is `postgres:5432` in podman and in the
  cluster alike ([ADR 0012](../../docs/adr/0012-datastore-reachability.md)).
- **demo-api-bluegreen** — the same pod template in a `Rollout`; `active` and `preview`
  Services, one `HTTPRoute` per hostname. Blue/green switches Service selectors and needs no
  router plugin.
- **demo-mqtt** — mosquitto with two listeners: MQTT over WebSocket on
  `wss://demo-mqtt.apps.<domain>/mqtt` through the edge (no new port; the only option for
  browsers), and plain MQTT on a named raw TCP entrypoint via `IngressRouteTCP`
  (`HostSNI(*)`: one port, one backend, plaintext — prefer the WebSocket path).
- **envs/** — Namespaces are declared explicitly (`CreateNamespace=false`) because the platform
  acts on their labels; `LimitRange` defaults; for branch environments a `ResourceQuota`
  (2 CPU / 2 Gi limits / 4 pods: one service at 1 CPU / 1 Gi, twice, because a terminating pod
  still counts against the quota during a rollout).

## Branch environments

One environment per merge request, created and removed with it, by an ApplicationSet in the
`argocd` namespace (it needs a GitLab token with `read_api`; created by an Argo CD administrator,
not by the root pointer, which may only create Applications):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: demo-branch-envs
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - pullRequest:
        gitlab:
          project: "demo/service"                # the source repository whose MRs count
          api: https://gitlab.dev.example.com/
          labels: [branch]                       # opt-in per merge request
          tokenRef: {secretName: gitlab-mr-token, key: token}
        requeueAfterSeconds: 300
  template:
    metadata:
      name: "demo-env-mr{{ .number }}"
    spec:
      project: demo
      source:
        repoURL: https://gitlab.dev.example.com/demo/gitops.git
        targetRevision: main
        path: envs/branch
        kustomize:
          namespace: "demo-mr{{ .number }}"      # renames the Namespace object too
      destination:
        server: https://kubernetes.default.svc
        namespace: "demo-mr{{ .number }}"
      syncPolicy:
        automated: {prune: true}
```

The services of a branch environment follow the same pattern (one more generator template per
service, image tag `mr<iid>-<sha>`, hostname `demo-api-mr<iid>.apps.<domain>`). Branch
environments share one secrets path (`kv/demo/env/branch`): anything that needs a manual write
per automatically created environment degrades in practice.

## Canary instead of blue/green

Weighted canaries go through the Gateway API plugin (`argoproj-labs/gatewayAPI`, installed by
the platform). The `HTTPRoute` lists both Services; Rollouts rewrites the weights:

```yaml
strategy:
  canary:
    stableService: demo-api-stable
    canaryService: demo-api-canary
    trafficRouting:
      plugins:
        argoproj-labs/gatewayAPI:
          httpRoute: demo-api
          namespace: demo-dev
    steps:
      - setWeight: 10
      - pause: {}
      - setWeight: 50
      - pause: {duration: 10m}
```

## Rules of the road

- **Never `hostNetwork`, `hostPort`, `NodePort` or `LoadBalancer`.** They bypass the edge and
  the host firewall; a host port the cluster gateway needs keeps the gateway — and every HTTP
  route on the platform — from starting. Non-HTTP traffic: ask for a named TCP entrypoint.
- **No TLS in routes or pods.** The edge terminates TLS for HTTP and WebSocket.
- **`imagePullSecrets: [{name: registry-pull}]`** in every pod spec that pulls private images —
  the platform delivers the Secret to labelled namespaces but attaches it to nothing.
- **Immutable image tags,** never `latest`: a moving tag leaves Git unchanged, so nothing is
  deployed and nobody knows what runs.
- **Resource limits everywhere:** the host also runs services the cluster cannot see.
- **`apiVersion: external-secrets.io/v1`** for ExternalSecrets (v1beta1 is not served).
- **Secrets never go into this repository** — they live in OpenBao, `ExternalSecret`s say which.

## Validate

```bash
# every manifest file (kustomizations are checked by building them)
kubeconform -strict -summary -skip Kustomization -kubernetes-version 1.33.0 \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  $(find . -name '*.yaml')
# what Argo CD will apply, per overlay
kustomize build apps/demo-api/overlays/dev | kubeconform -strict -summary …
```
