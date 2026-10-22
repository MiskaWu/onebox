# roles/casdoor — the bundled OIDC identity provider

Casdoor issues the identities every platform service trusts (`onebox_oidc_issuer` =
`https://{{ casdoor_hostname }}`, i.e. `sso.<domain>`). It can broker an upstream directory
(any OIDC provider, Microsoft Entra ID, Google, GitHub) so that rotating the upstream client
secret touches only Casdoor. Run without this component by pointing `onebox_oidc_issuer` at your
own provider. Why one issuer, why a broker, why internal-only:
[ADR 0018](../../docs/adr/0018-one-oidc-issuer.md).

Component: `casdoor` (needs `edge`; in `shared` database mode also `datastores` — asserted in
`tasks/preflight.yml`, because `onebox_component_requires` is static and cannot express it).

## What it runs

| | |
|---|---|
| Container | `casdoor`, pinned image, `127.0.0.1:{{ casdoor_http_port }}` (8000) only |
| Edge | `https://sso.<domain>`, internal-only |
| Configuration | `casdoor_root/conf/app.conf` — no secrets: the DSN, the first admin password and the RADIUS secret are podman secrets in environment variables of the same names, which Casdoor reads before the file |
| Declarations | `casdoor_root/secrets/init_data.json` (root-only directory): the organisation, one application per OIDC client, the upstream providers |
| Database | `shared`: the datastores PostgreSQL; `dedicated`: its own `casdoor-db` container |

### Database modes (`casdoor_db_mode`)

- **`shared`** (default): the role creates its login role and database in the datastores
  PostgreSQL (`podman exec postgres psql` over the unix socket), owned by that role, before
  Casdoor's first start — Casdoor does not create its database (`createDatabase` defaults to
  off) and exits without it. Casdoor joins `onebox-data` and connects to `postgres:5432`; its unit
  requires `postgres.service`, so a database restart restarts Casdoor instead of leaving a
  half-broken connection pool. Cost: shared fate and maintenance windows with every other tenant.
  The datastores reset protects this database.
- **`dedicated`**: `casdoor-db` (PostgreSQL) on the internal network `casdoor-db` (no route out,
  nothing published); Casdoor joins it plus podman's default network for outbound calls to
  upstream providers. The isolation escape hatch of ADR 0011.

Switching modes does not move data.

## Declarative objects, converged on every start

`initDataMerge = true` (Casdoor ≥ 4.18): every start applies the init data — missing objects are
created, existing ones get exactly the fields declared, other fields edited in the UI stay. A
changed redirect URI or a rotated client secret therefore converges with `make casdoor`; the
file changes, the handler restarts Casdoor (a single-file bind mount keeps the inode it started
with, so a restart is what makes the new file visible anyway). Objects removed from the
declarations are *not* deleted (an application of a component you switched off, a provider you
dropped): delete those in the UI. Nothing touches the `built-in` organisation — declaring it
would make Casdoor replace it.

- **Organisation** `casdoor_organization` (default `onebox`), where people live. Never
  `built-in` (preflight refuses it): every user of the built-in organisation is a global
  administrator, whatever flags the account carries. The name is part of every identity
  (`<organisation>/<user>`); renaming creates new identities.
- **Applications**: one per entry of `onebox_oidc_clients` whose component is enabled (an entry
  may name its component with `component:`; default: its key). Client ID and secret are the
  secrets `<name>_oidc_client_id` / `<name>_oidc_client_secret`, the same keys the service
  reads. **Never create these applications by hand**: the UI generates its own pair, which no
  service holds. Client IDs must be distinct — Casdoor silently skips an application whose
  client ID another one already uses. Treat every client secret as an administrator key: with
  Casdoor, any application's client secret authenticates to the management API as a global
  administrator.
- **Upstream providers** (`casdoor_identity_providers`, catalog in `vars/main.yml`): `oidc`
  (issuer + authorization URL; token and userinfo endpoints are discovered from the issuer),
  `azuread` (tenant **required** — an empty tenant falls back to the multi-tenant `common`
  endpoint, i.e. any Microsoft account; register the upstream app single-tenant as well),
  `google`, `github`; add more through `casdoor_idp_catalog_extra`. Accounts are matched to
  existing ones only by a verified email or phone from the provider.

After the start the role checks from loopback that the issuer Casdoor announces is the one the
services trust, and that each declared client ID resolves to an application (an unknown grant
type is answered `unsupported_grant_type` only for a known client ID; `invalid_client` means
none). That proves the ID, not the secret.

## Security boundary

1. **Internal-only vhost.** The identity provider's real boundary is the network
   (ADR 0006/0018). Server-to-server calls (discovery, token exchange) come back through the edge
   from container and pod addresses, so `casdoor_internal_client_cidrs` (podman's default network,
   the data network, the pod CIDR) are allowed too — miss one and single sign-on fails with 403
   for that service. Making the vhost public needs `casdoor_allow_public: true` on purpose.
2. **Self sign-up is closed.** `disableSelfSignup` (Casdoor ≥ 4.19) separates the local
   registration page and API from upstream auto-provisioning, which older versions tied to one
   switch — the sign-up API then accepted arbitrary, unverified email addresses and could even
   return an authorisation code, bypassing any upstream tenant restriction (verified closed on
   the pinned version: the API answers "The application does not allow to sign up new account").
   `casdoor_idp_signup` decides whether a first upstream sign-in creates an account.
3. **The first admin password comes from `secrets.yml`** (`initAdminPassword`, Casdoor ≥ 4.19).
   Without it, `built-in/admin` starts with no password and the first visitor of the welcome page
   sets one. It applies once, when the admin is created; change it later in the UI (and in
   `secrets.yml` for your records). The built-in admin is the break-glass path that does not
   depend on any upstream provider; hiding the password form (`casdoor_password_form: false`) is
   cosmetic — the API still accepts passwords.
4. **Listeners nobody asked for**: the built-in LDAP server is switched off; the RADIUS listener
   cannot be (no switch in this version), so it gets a secret derived from the database password
   instead of the upstream default `secret`. Neither port is published.

## Secrets

| Key | |
|---|---|
| `casdoor_db_password` | Casdoor's database role (any characters) |
| `casdoor_admin_password` | first password of `built-in/admin` (≥ 12 chars, no blanks) |
| `<name>_oidc_client_id`, `<name>_oidc_client_secret` | per enabled client (gitlab, argocd, openbao) — owned by those services, registered here |
| `casdoor_idp_<name>_client_secret` | per upstream provider (`-` in the name becomes `_`) |

## Operations

- `journalctl -u casdoor` [`make casdoor-logs`] — init data errors show up here (Casdoor refuses
  to start on an invalid declaration).
- The database: `podman exec -it postgres psql -U postgres casdoor` (shared) or
  `podman exec -it casdoor-db psql -U casdoor casdoor` (dedicated). Backups follow the database.

## Pitfalls this role handles

- **`origin`** in app.conf is where the issuer comes from; it must equal `onebox_oidc_issuer`
  exactly or every client rejects the tokens (checked after each start).
- **`initDataFile` must be set** in the app.conf the role mounts — it replaces the image's own, and
  without the key the init data is silently ignored.
- **PostgreSQL DSN** is libpq keyword/value (not a URL) and must contain `dbname=`: Casdoor only
  appends the database name for MySQL. The password is quoted, so any character works.
- **Image user** 1000: the init data belongs to that uid (mode 0400) inside a root-only
  directory, so the container can read it and no other host account can reach it. Rootful podman
  maps container uid 1000 to host uid 1000 — whoever that is on the host never gets to the file.
- **Version-sensitive facts** above were verified against the pinned 4.22.0 (source and a live
  instance). Casdoor ships a minor for almost every merged batch: read the release notes of a
  bump for authentication changes and re-check them.
