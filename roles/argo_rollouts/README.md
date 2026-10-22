# roles/argo_rollouts — blue/green and canary releases

Argo Rollouts, pinned and installed through a k3s `HelmChart`, with the Gateway API
traffic-router plugin for weighted canaries. Argo CD applies what Git declares; Rollouts decides
*when* a new version receives traffic. Decision: [ADR 0015](../../docs/adr/0015-loopback-cluster-gateway.md).

Component: `argo-rollouts` (needs `k3s`; the plugin also needs `k3s-gateway`).

## Two strategies, two very different dependencies

| Strategy | Mechanism | Depends on |
|---|---|---|
| **Blue/green** | the controller points the *active* and *preview* Services' selectors at the stable and new ReplicaSets | nothing — works with HTTPRoute, Ingress, raw TCP alike |
| **Weighted canary** | the plugin edits `backendRefs[].weight` of an `HTTPRoute` | Gateway API + the plugin |

The plugin is pre-1.0. Keeping blue/green independent of it is deliberate: a plugin problem
affects canaries only. Automatic promotion stays off in the examples — deployment is automatic
(the GitOps bump), *switching traffic* is a person's decision; they are separate gates.

## What it deploys

`onebox-argo-rollouts.yaml`: `HelmChart argo-rollouts` with

- the chart archive pinned by version and repository digest, served by k3s;
- `failurePolicy: abort` and `keepCRDs: true` — uninstalling must never delete the CRDs, which
  would delete every Rollout and its ReplicaSets;
- one controller replica (one node: a second would only run leader election), resource limits;
- the plugin `argoproj-labs/gatewayAPI` at `argo_rollouts_gatewayapi_plugin_version`, with the
  sha256 GitHub publishes for the release asset of the node's architecture. The name is part of
  the protocol: Rollouts reference exactly this string. The chart grants the plugin's RBAC on
  HTTPRoutes (`providerRBAC.providers.gatewayAPI`);
- no dashboard: `kubectl argo rollouts get rollout <name> --watch` shows the same with the
  caller's own permissions (the CLI plugin is a personal tool, not part of the host).

The converge waits for k3s to apply the file and for the controller deployment to be available.
The controller downloads the plugin when it starts and does not run with a plugin it could not
fetch or whose checksum differs, so "available" includes "plugin loaded"; on failure the plugin
log lines are printed.

## Using it

Blue/green (full example: `examples/gitops/apps/demo-api-bluegreen/`):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
spec:
  strategy:
    blueGreen:
      activeService: demo-api-bg-active      # the HTTPRoute points here
      previewService: demo-api-bg-preview    # second hostname for checking the new version
      autoPromotionEnabled: false
```

```bash
kubectl argo rollouts -n demo-dev get rollout demo-api-bg --watch
kubectl argo rollouts -n demo-dev promote demo-api-bg     # switch traffic
kubectl argo rollouts -n demo-dev undo demo-api-bg        # switch back
```

Canary through the plugin:

```yaml
  strategy:
    canary:
      stableService: demo-api-stable
      canaryService: demo-api-canary
      trafficRouting:
        plugins:
          argoproj-labs/gatewayAPI:
            httpRoute: demo-api            # backendRefs: stable and canary Services
            namespace: demo-dev
      steps:
        - setWeight: 10
        - pause: {}
        - setWeight: 50
        - pause: {duration: 10m}
```

## Operations

```bash
sudo make argo-rollouts
kubectl -n argo-rollouts get deploy,pods
kubectl -n argo-rollouts logs deploy/argo-rollouts | grep -i plugin
```

Upgrade: bump chart version, sha256 and app version; bump the plugin version with its two
checksums separately (read its release notes — weight semantics changed in 0.17 for
`maxTrafficWeight` above 100). Remove: move workloads back to Deployments first; Rollouts without
a controller stop progressing.

## Pitfalls

- **The controller needs github.com at every start** (the plugin is not baked into the image).
  A plugin that cannot be fetched keeps the controller down; blue/green stops progressing too.
- **A misspelt plugin name** gives a running controller and Rollouts that cannot find their
  router.
- **Canary without Gateway API CRDs** fails only when the first canary runs — hence the
  preflight requiring `k3s-gateway` while the plugin is enabled.
