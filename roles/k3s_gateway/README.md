# roles/k3s_gateway — the cluster gateway

HTTP entry into the cluster: our own pinned Traefik on the host network, every entrypoint bound
to an explicit address (127.0.0.1 for HTTP), serving both `Ingress` and Gateway API. The edge
proxies cluster hostnames to it; nothing else reaches it. Decision and rejected alternatives:
[ADR 0015](../../docs/adr/0015-loopback-cluster-gateway.md).

Component: `k3s-gateway` (needs `k3s`, `edge`).

```
client ──443──► edge (Caddy, TLS, LAN guard)  *.apps.<domain>, argocd.<domain>, …
                   │ reverse_proxy 127.0.0.1:31080   (Host header preserved)
                   ▼
              Traefik  hostNetwork, web entrypoint 127.0.0.1:31080, no Service
                   │ HTTPRoute / Ingress / IngressRouteTCP
                   ▼
                 pods
```

## Naming cheat-sheet

This layer is called **gateway** everywhere; "ingress" only ever means the `Ingress` object.

| What | Name |
|---|---|
| component / make target / tag | `k3s-gateway` |
| role, variables | `roles/k3s_gateway`, `k3s_gateway_*` |
| manifests | `onebox-k3s-gateway.yaml` (HelmChart), `onebox-k3s-gateway-crds.yaml` (Traefik CRDs), `onebox-gateway-api-crds.yaml` |
| HelmChart object | `kube-system/k3s-gateway` |
| namespace | `gateway` (`k3s_gateway_namespace`) |
| `Gateway` workloads attach to | `gateway/onebox` (`k3s_gateway_name`) — named after the platform, so swapping the engine keeps every route |
| `GatewayClass`, default `IngressClass` | `traefik` (`k3s_gateway_class`) — a class names its implementation |
| engine | Traefik, the only pod; everything else is a declaration |

| Object | Who writes it | Use it for |
|---|---|---|
| `HTTPRoute` | workloads | **all new HTTP routes** (portable, weighted backends for canaries) |
| `Ingress` | charts that only ship Ingress (Argo CD) | existing charts; frozen upstream, not removed |
| `IngressRouteTCP` | workloads | raw TCP on a named entrypoint (Traefik CRD; unrelated to `Ingress` despite the name) |
| `Gateway`, `GatewayClass` | this role (chart) | the door and its implementation |

## How it is installed

1. **Gateway API CRDs** — `standard-install.yaml` of `k3s_gateway_gatewayapi_version`, pinned by
   sha256, written to the manifests directory; the role waits until k3s applied it.
2. **Chart archive** — downloaded with the sha256 from the chart repository index into k3s's
   static directory (`/var/lib/rancher/k3s/server/static/charts/`). The HelmChart points at
   `https://%{KUBERNETES_API}%/static/charts/…`, the mechanism k3s uses for its own packaged
   charts: reconciles never need the chart repository, and a re-published archive fails loudly.
3. **Traefik CRDs** — Helm installs a chart's `crds/` directory once and never upgrades it, so the
   `traefik.io_*` CRDs are taken from the pinned chart and applied by k3s; a chart bump updates
   them too.
4. **HelmChart** `k3s-gateway` with `failurePolicy: abort` (a failed upgrade leaves the old pod
   serving instead of uninstalling it).
5. **Verification:** Traefik answers 404 on `127.0.0.1:<port>` for an unknown host, `ss` shows the
   port held by Traefik on 127.0.0.1 and not on `0.0.0.0`/`*`, and the `Gateway` is
   `Programmed`.

Values worth knowing (all in the template, each checked against the chart's
`values.schema.json`):

- `hostNetwork: true`, `dnsPolicy: ClusterFirstWithHostNet`, `updateStrategy: Recreate` with
  `rollingUpdate: null` (one node cannot run two pods on the same host ports).
- `service.enabled: false` — no Service, hence no NodePort/LoadBalancer path around the edge.
- `ports.web.asDefault: true` — routers that name no entrypoint attach to `web` only, never to a
  raw TCP entrypoint where an HTTP route would be reachable around the edge's LAN guard.
- `forwardedHeaders.trustedIPs: [127.0.0.1/32]` — the edge is the only client.
- `ingressEndpoint.ip` / Gateway `statusAddress.ip` = 127.0.0.1 — without a Service there is no
  address to publish; with these, `Ingress` objects get a status and Argo CD reports them Healthy
  instead of Progressing forever.
- The listener accepts routes from **all namespaces** (`namespacePolicy.from: All`); the default
  (same namespace only) leaves routes `Accepted=False` while every pod is green.

## Edge forwarding

`k3s_gateway_vhost_entries` (consumed by `caddy_vhost` in `site.yml`) is derived:

- `k3s_gateway_edge_wildcard: true` (default): one catch-all site
  `*.<k3s_gateway_apps_domain>` (default `*.apps.<domain>`). A new environment is just a new
  route in the cluster. Caddy matches the most specific site first, so `gitlab.`, `argocd.` …
  keep their vhosts, and a mistyped platform name lands at the edge, not in the cluster
  (ADR 0006). The certificate must be a wildcard: **`edge_tls_mode` `acme_dns`, `internal`, or
  `files` with a certificate covering `*.apps.<domain>`**. A wildcard covers one label:
  `demo-api.apps.dev.example.com` yes, `a.b.apps.dev.example.com` no.
- `acme_http` cannot issue wildcards: set `k3s_gateway_edge_wildcard: false` and list each name:

  ```yaml
  k3s_gateway_hostnames:
    - hostname: demo-api.apps.dev.example.com
      title: Demo API                # portal card; portal: false hides it
    - hostname: demo-mqtt.apps.dev.example.com
      portal: false
  ```

  Entries take every `caddy_vhost` key except `upstream` (always the gateway). With the wildcard
  on, list a name only to give it a portal card or different access (`internal_only`,
  `allow_cidrs`).

Every entry gets `lb_try_duration` (the edge retries during the seconds a gateway restart takes)
and `stream_close_delay` (WebSockets survive edge reloads). DNS: the platform's wildcard record
`*.<domain>` also resolves names below `apps.`.

## Raw TCP (opt-in)

Non-HTTP traffic is off by default; in order of preference (ADR 0015):

1. **WebSocket through the edge** — zero new ports (see `examples/gitops/apps/demo-mqtt`).
2. **TLS + SNI on one shared port** — *not implemented yet*: it needs the edge's certificate
   synced into the cluster on a timer.
3. **Named TCP entrypoints** — this role:

   ```yaml
   k3s_gateway_tcp_entrypoints:
     - name: demo-mqtt        # = spec.entryPoints of the workload's IngressRouteTCP
       port: 1883
       allowed_cidrs: [192.0.2.0/24]   # firewalld sources (default onebox_internal_cidrs)
   ```

   Bound to `k3s_gateway_tcp_bind_ip` (default `onebox_host_ip`, never `0.0.0.0`), opened in
   firewalld per port — these are host-native sockets, so the firewall really filters them
   (ADR 0007). Without TLS a TCP router can only match ``HostSNI(`*`)``: one port, one backend.
   The name is a contract: a mismatch silently creates no router.
4. **NodePort** — avoid: DNAT'd, all-or-nothing, invisible to the firewall.

Removing an entry does not close its firewall port (ensure-present helper) — close it by hand.

## Operations

```bash
sudo make k3s-gateway                                   # converge
sudo ss -ltnp 'sport = :31080'                          # must be traefik on 127.0.0.1 only
kubectl -n gateway get gateway,pods                     # Programmed=True, one pod
kubectl get httproute -A                                # routes and their Accepted status
kubectl -n kube-system get helmchart k3s-gateway -o jsonpath='{.status}'
```

Upgrade: bump `k3s_gateway_chart_version`, `_sha256`, `_app_version` (from the repository's
`index.yaml`), check the chart's Changelog for moved values keys and the Gateway API version
its Traefik expects, bump `k3s_gateway_gatewayapi_*` with it, `make check TAGS=k3s-gateway`,
converge. Expect a few seconds of downtime (Recreate); the edge retries HTTP requests meanwhile.

Removal: add `onebox-k3s-gateway` to `k3s_disable` and run `make k3s` (k3s uninstalls the
AddOn's objects and removes the file); the CRD bundles stay unless you add their AddOn names
too — deleting CRDs deletes every route object of that kind.

## Pitfalls

- **One unbindable port takes everything down.** A hostNetwork pod that cannot bind one of its
  ports does not start; every HTTP route goes with it. The role checks bind addresses and
  current port holders (by process name — a stray `kubectl port-forward --address 0.0.0.0`
  looks exactly like a workload) before changing the manifest.
- **NodePorts hijack loopback ports.** kube-proxy DNATs NodePorts on 127.0.0.1 too; the gateway's
  ports are kept outside k3s's narrowed NodePort range (roles/k3s).
- **Helm ignores unknown values keys.** Keys move between chart majors (logging moved from
  `logs.*` to `log`/`accessLog` once); a stale key is "configured" and has no effect.
- **The bundled Traefik must stay disabled** (k3s preflight), and nothing here may be named
  `traefik.yaml`.
