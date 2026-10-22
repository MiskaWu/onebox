# 0020. Remote access extends the LAN through an outbound-only mesh VPN

- Status: Accepted
- Related: [0006](0006-internal-only-by-default.md), [0010](0010-podman-quadlet-services.md), [0018](0018-one-oidc-issuer.md)

## Context

Some people work outside the LAN. Typical constraints: no control over the upstream router (no
port-forwarding), no budget for a managed VPN, a handful of users, and services that are
internal-only by design ([0006](0006-internal-only-by-default.md)).

## Decision

- **Tailscale on the host** (the optional `tailscale` component). It only dials out; access is
  governed by tailnet ACLs; the tailnet address range is added to the internal ranges the edge
  trusts.
- **Tailnet Lock is enabled at setup:** new nodes must be signed by trusted nodes, so the
  coordination service cannot add a node on its own.
- **Removal is one previewed command:** it logs the node out (otherwise a ghost node keeps its
  key trusted and occupies a device slot), disables the daemon, removes the package and the state
  directory (otherwise a reinstall rejoins with the old identity), and unbinds firewall settings.
  Run it from the LAN or the console, never over the tailnet.

## Consequences

- Remote people see exactly the LAN view; nothing becomes public.
- Accepted cost: identities live outside the corporate identity provider on simple plans, so
  offboarding includes removing the person's devices by hand.
- Accepted cost: a third-party control plane (mitigated by Tailnet Lock: the relays only ever
  carry ciphertext and node keys never leave the endpoints).
- Accepted cost: plan terms can change. Check that your plan permits your use; for some
  providers, how the account is created (personal versus company domain) changes how it is
  classified.

## Alternatives considered

- **Exposing services publicly:** forges regularly ship vulnerabilities exploitable before
  authentication, the identity provider's real boundary is the network
  ([0018](0018-one-oidc-issuer.md)), and pinned, manually bumped images
  ([0010](0010-podman-quadlet-services.md)) assume no public inbound. Exposure would commit the
  team to patching on the attacker's schedule.
- **Self-hosted WireGuard on the host:** needs an inbound UDP port.
- **A WireGuard hub on a cloud VM:** the hub decrypts and routes; compromising it yields
  plaintext and a LAN foothold. Mesh relays forward ciphertext only.
- **A zero-trust proxy service that terminates TLS:** sees source code and credentials in clear,
  and conflicts with "only the edge terminates TLS".
- **A managed client VPN:** recurring cost for a handful of users.

## Revisit when

- Offboarding needs central, immediate revocation tied to the corporate identity provider:
  self-host a mesh control plane with IdP integration (for example NetBird). It needs a public
  machine — decide first which repository manages it. Headscale does not solve this need (no
  SAML SSO).
- Plan terms or pricing change, or the user count outgrows the plan.
