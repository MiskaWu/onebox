# 0018. One OIDC issuer for every platform service

- Status: Accepted
- Related: [0006](0006-internal-only-by-default.md), [0009](0009-guarded-irreversible-changes.md), [0016](0016-gitops-central-repository.md), [0017](0017-openbao-and-external-secrets.md)

## Context

The forge, Argo CD and OpenBao need single sign-on. Some organisations already run an identity
provider (Entra ID, Google Workspace, Keycloak); others have none. Every place that holds an
upstream client secret is a place to touch when that secret rotates.

## Decision

- **One issuer:** `onebox_oidc_issuer` is trusted by every platform service. By default it is the
  bundled Casdoor, which can broker to an upstream provider; set it to any OIDC provider to run
  without the `casdoor` component.
- **Clients are declared once,** in `onebox_oidc_clients` (name, title, redirect URIs); their IDs
  and secrets are the secrets `<name>_oidc_client_id` / `<name>_oidc_client_secret`. When Casdoor
  is enabled, convergence creates the applications. **Never create them by hand:** the UI
  generates its own client ID and secret, and services end up holding a pair the identity
  provider does not know. Casdoor's init data runs in merge mode (4.18+), so declarations are
  converged on every start — existing objects included.
- **Why a broker:** when the upstream client secret rotates, only the broker changes; services
  (some of which reconfigure slowly) are untouched. Accepted cost: one more stateful component —
  single sign-on is down while it is down.
- **The identity provider is internal-only.** Older Casdoor releases tied local self-sign-up
  and upstream auto-provisioning to one switch, and the sign-up API accepted arbitrary,
  unverified email addresses — even returning an authorisation code that bypassed any upstream
  tenant restriction. Since 4.19 they are separate switches and onebox disables self-sign-up
  outright, but the network boundary ([0006](0006-internal-only-by-default.md)) stays the real
  control: hiding a form is cosmetic, an unreachable endpoint is not.
- **Client secrets are administrator keys** in the threat model: with Casdoor, any application's
  client secret authenticates to its management API as a global administrator.
- **The built-in organisation is for named administrators only.** Users auto-provisioned through
  a provider attached to it become global administrators. Providers there have sign-up disabled
  and an explicitly empty binding-rule list (an unset list falls back to matching email, phone or
  name — an attacker-chosen email could bind to an admin).
- **Upstream tenant lock is double:** the upstream app registration is single-tenant *and* the
  broker's provider names the tenant (an empty tenant falls back to multi-tenant).
- **Authorisation in consuming services is an allowlist that fails closed:** OpenBao's bound
  email claims and Argo CD's RBAC default to deny / read-only. Known gap: an allowlisted email
  that has no account yet can be claimed through self-sign-up. Grant only to people who have
  signed in once (the grant command says so in its output); move to group-based authorisation
  when the list grows.
- **No default-password window.** The administrator's first password comes from the secrets
  file (`initAdminPassword`, 4.19+) instead of the vendor default followed by a rotation step —
  the old set-password call was not idempotent and needed its own operation target. Making an
  identity-provider vhost public still requires an explicit flag (`casdoor_allow_public`).

## Consequences

- One login everywhere; identities are the same string in every service.
- Accepted cost: the broker is a single point of failure for interactive logins; break-glass
  paths that do not depend on it stay documented ([0009](0009-guarded-irreversible-changes.md)).
- Product facts above were verified against one Casdoor release line; re-verify after upgrades
  that touch authentication.

## Alternatives considered

- **Each service talks to the upstream provider directly:** several rotation points and several
  identity sources.
- **Dex in Argo CD:** two brokers in series.
- **Bundling Keycloak:** more capable, much heavier; supported as a bring-your-own issuer.
- **Disabling sign-up entirely:** also disables upstream auto-provisioning; the right move only
  when the provider must face the internet (then provision users explicitly).

## Revisit when

- The broker costs more to run than the rotations it saves.
- The identity provider must be public: disable sign-up, provision users explicitly, re-evaluate
  the break-glass password form.
- More than a handful of administrators, or tenants: authorise by group membership.
