# 0005. Certificates: DNS-01 for LAN-only names, TLS mode as a provider, ACME only at the edge

- Status: Accepted
- Related: [0004](0004-host-native-edge-proxy.md), [0006](0006-internal-only-by-default.md), [0015](0015-loopback-cluster-gateway.md)

## Context

Most onebox hosts are reachable only inside a LAN or VPN, with no inbound traffic from the
internet. Clients — browsers, `git`, container runtimes, kubelets — should trust the
certificates without anyone installing a private root CA on every laptop and runner. Some
environments are public, some air-gapped, some have a corporate CA.

## Decision

- **Default `edge_tls_mode: acme_dns`.** ACME DNS-01 through the zone's DNS API: it needs no
  inbound port, works for names that resolve only to private addresses, and can issue
  wildcards. Names resolve through one wildcard record (`*.<onebox_domain>` → host IP); the
  apex is not covered by the wildcard and needs its own record.
- **TLS mode is a provider variable:** `acme_dns` | `acme_http` (the host is reachable from the
  CA on 80/443) | `internal` (Caddy's own CA; clients must trust its root) | `files` (a
  certificate you provide, typically a corporate wildcard).
- **DNS providers are catalog entries** (Go module, Caddy module ID, secret environment
  mapping, default options). Built in: `route53`, `cloudflare`, `rfc2136`. Adding a provider is
  an entry in `edge_dns_catalog_extra`, never a template branch.
- **Only the edge speaks ACME and holds DNS credentials,** scoped to the one zone (for example:
  change/list record sets and read change status on one hosted zone; a token with DNS edit on
  one zone; a TSIG key allowed to update only `_acme-challenge` names). Services and the
  cluster speak plain HTTP on loopback. If something inside the cluster genuinely needs the
  certificate (TLS termination for a non-HTTP port), it receives a one-way copy from the edge
  on a timer — never a second ACME client with its own DNS credentials.
- **Delegate each environment's subdomain as its own zone** where possible, so the DNS
  credential's blast radius is one environment's records. One wildcard level per environment
  (`*.dev.example.com`, `*.prod.example.com`), never overlapping.

## Consequences

- Zero client setup in `acme_dns`/`acme_http`/`files` modes; one place for TLS policy.
- The DNS credential is the most sensitive external credential on the host.
- DNS-01 succeeds even when the name has no address record: the certificate is issued and
  nobody can connect. The wildcard record removes that failure, and a status check that
  resolves every declared hostname catches a deleted wildcard or a missing apex record. It
  cannot catch a missing per-service record while the wildcard exists — the check must say so
  in its output rather than print a clean pass.
- With a wildcard record, typos resolve and land at the edge (403/404 there) instead of failing
  early with NXDOMAIN.
- A certificate copied into the cluster expires silently unless the sync runs on a schedule:
  the edge renews about every 60 days, convergence may run far less often. The symptom (every
  TLS client of that port fails while the edge looks healthy) is hard to trace.
- Wildcard certificates require DNS-01, `internal` or `files`; `acme_http` can only issue
  per-name certificates, so wildcard site addresses need one of the other modes.

## Alternatives considered

- **A private CA everywhere:** a root to install on every laptop, Git client, container runtime
  and CI image, forever.
- **HTTP-01 by default:** requires inbound reachability most hosts do not have.
- **ACME in each service or cert-manager in the cluster:** a second ACME client and a second set
  of DNS credentials inside the cluster.
- **Automating per-service A records through the DNS API:** some providers need request signing
  that plain HTTP modules cannot do without collections; once a wildcard exists the value is
  close to zero.

## Revisit when

- Non-address records must be managed (mail SPF/DKIM): that is where DNS automation earns its
  dependency.
- You decide to drop the wildcard in favour of explicit records (typos fail early).
- The host becomes publicly reachable: `acme_http` may be enough.
