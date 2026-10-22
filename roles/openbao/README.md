# roles/openbao — the secrets store for workloads

OpenBao (the community fork of Vault) holds the values; External Secrets
([roles/external_secrets](../external_secrets/README.md)) delivers them into the cluster as
Kubernetes Secrets. Why on the host and not in the cluster, why static auto-unseal, why Ansible
and not the server's self-initialisation:
[ADR 0017](../../docs/adr/0017-openbao-and-external-secrets.md).

Component: `openbao` (needs `edge`). Kubernetes auth is configured when `external-secrets` is
also listed.

**Boundary:** the platform's own secrets stay in `secrets.yml`, never in OpenBao — the code that
deploys OpenBao cannot depend on OpenBao being up.

## What it runs

| | |
|---|---|
| Container | `openbao`, pinned image, published on `127.0.0.1:{{ openbao_http_port }}` (8200) only |
| Edge | `https://{{ openbao_hostname }}` (`bao.<domain>`), internal-only; the pod CIDR is allowed so External Secrets can come in through the edge |
| Storage | integrated raft in `openbao_root/data` (`/var/lib/onebox/openbao/data`) |
| Configuration | `openbao_root/config/onebox.hcl` — no secrets in it, so `make check` shows its real diff |
| Seal | static auto-unseal, key from `secrets.yml` as a podman secret |
| State | `openbao_root/state/` (root-only): `root-token`, and `recovery-key.json` until you move it |
| Audit | file device to stdout → `journalctl -u openbao` (values HMAC'd) |

**Raft, not file:** 2.7 removed the `file` backend. Raft gives API snapshots for backups and a
path to more nodes; PostgreSQL storage would tie the secrets store to the shared database (its
maintenance windows and its reset), and PebbleDB arrived in 2.7.0 — too new for the one store
that every application's secrets depend on.

## Seal — read this part

A sealed OpenBao serves nothing. The options, as of 2.7:

| Seal | Unattended reboot | Trust root | Verdict here |
|---|---|---|---|
| Shamir (default) | no — a human types key shares after every restart | people | secrets delivery down until someone is online |
| Cloud KMS (`awskms`, `gcpckms`, `azurekeyvault`, `ocikms`, …) | yes | cloud KMS | plugins since 2.7; a new cloud dependency and cost |
| PKCS#11 / HSM | yes | hardware | plugin since 2.7; needs an HSM |
| Transit | yes | another OpenBao/Vault | the other store must exist first |
| **Static** (built in) | yes | a key on this host | **used** |

Stated honestly: with a static key, key and ciphertext sit on the same host, so this is no
stronger at rest than `secrets.yml` itself. The gains are elsewhere — dynamic delivery to the
cluster, an audit trail, per-application policy, revocation, values no longer copied around by
Ansible. Upstream recommends static keys only where another source of trust already exists;
`secrets.yml` (and your password manager) is that source. When an independent root of trust
appears (HSM, a company KMS, a separate transit store), moving to it is a pure upgrade — seal
migration, see the upstream docs.

**The key.** `openbao_seal_key` is a passphrase of at least 32 random characters
(`make secrets-gen KEY=openbao_seal_key LENGTH=48`); the role derives the 32-byte AES-256-GCM
key as its SHA-256 and the key id from a hash of that, so any change of key changes the id, as
the seal requires. **Losing the passphrase loses every secret, and backups cannot be decrypted
without it.** Copy it into your password manager the moment you create it.

**Rotation** (verified against 2.7.1): put the current passphrase in
`openbao_seal_previous_key` and a new one in `openbao_seal_key`, converge — the server unseals
with the old key and re-wraps with the new one — then remove `openbao_seal_previous_key` and
converge again (the role also deletes the old key's podman secret). Changing `openbao_seal_key`
alone leaves the store sealed: the converge stops with that explanation instead of carrying on.
Never delete the data directory to "fix" a sealed store.

## Initialisation, root token, recovery key

The first converge initialises the store (`bao operator init`, one recovery share). The output
goes from the container straight into a root-only file and is split into:

- `state/root-token` — kept: every converge re-applies mounts, policies and auth methods with it.
  Root on this host already holds the seal key and the data, so a root-only token file adds no
  power that was not there. The server's declarative self-initialisation would revoke the root
  token, but it runs once and cannot be changed afterwards — policies and sign-in lists change.
- `state/recovery-key.json` — **move it offline, then delete it**. It cannot decrypt anything; it
  authorises minting a new root token (`bao operator generate-root`) if the token file is lost.
  Every converge reminds you while it is still on the host.

## What convergence configures

All through the HTTP API on loopback; every call that carries the token is `no_log`. Mounts and
policies are read first and written only when they differ, so "changed" is honest.

- **KV v2** at `{{ openbao_kv_mount }}`. Layout: `platform/registry/<registry>/<tenant>`,
  `platform/datastore/<engine>`, `<tenant>/env/<tier>`.
- **Policies**: `onebox-admin` (everything incl. `sudo`, but not root), `onebox-writer` (values
  under the KV mount), `onebox-reader` (reads every value — not a harmless "list" tier),
  `onebox-external-secrets` (read-only KV for the machine; separate from `reader`, which also
  carries the web UI's mount-listing paths — without those a person signs in to an empty page).
- **OIDC sign-in** against `onebox_oidc_issuer` (when set), one role per tier:

  | Tier | Who | Policy |
  |---|---|---|
  | `admin` | `openbao_oidc_admins` | `onebox-admin` |
  | `writer` | writers + admins | `onebox-writer` |
  | `reader` | readers + writers + admins | `onebox-reader` |

  Members are values of `openbao_oidc_bind_claim` (`email` by default, or e.g. `groups` for group
  names). **The lists are the authorisation boundary**: signing in to the identity provider proves
  an identity, not a right to the store. Preflight refuses an empty admin list (fail closed:
  otherwise anyone who can sign in would get a policy) and a default role that does not include
  everyone (people who leave the UI's Role field empty would be refused with an error that never
  says "type a role" — the UI cannot list roles before login). A tier that becomes empty has its
  role deleted, not merely left alone: a stale role keeps admitting the people just removed.
  The redirect URIs come from `onebox_oidc_clients.openbao`; the `…/ui/vault/auth/oidc/oidc/callback`
  path is the UI's own route ("vault" is not a typo) and the CLI uses `http://localhost:8250/oidc/callback`.
- **Kubernetes auth** (with `external-secrets`) at `{{ openbao_k8s_auth_mount }}`:
  `kubernetes_host` = `openbao_k8s_api_url` (`https://<onebox_host_ip>:6443` — the address as seen
  from the container; its `127.0.0.1` is its own loopback), the k3s server CA from
  `openbao_k8s_ca_file`, **no** `token_reviewer_jwt` (OpenBao reviews the client's own
  service-account token, so no long-lived credential exists on either side; the cluster grants
  that account `system:auth-delegator`), and role `{{ openbao_eso_role }}` bound to
  `{{ external_secrets_namespace }}/{{ external_secrets_service_account }}` with the read-only
  policy. The role opens the API port in firewalld for podman's default network
  (`openbao_container_cidr`) only — the API stays closed to the LAN.

**Ordering.** Sign-in needs the issuer to answer and Kubernetes auth needs k3s. When either is
not there yet (a first converge of a new host), that part is skipped with a note, and the next
`make openbao` completes it — nothing fails. `tasks/kubernetes_auth.yml` is self-contained and
can be included on its own.

**Trusting the issuer.** OpenBao fetches the issuer's discovery document itself, from inside the
container, and validates its certificate. A publicly trusted issuer needs nothing. With the
bundled Casdoor behind an edge in `internal` TLS mode the role passes the edge's CA
(`onebox_edge_ca_file`) automatically; for a private CA set `openbao_oidc_ca_file` or
`openbao_oidc_ca_pem`. The issuer's vhost must also admit the container's address (Casdoor's
vhost allows podman's default network).

## Secrets

| Key | |
|---|---|
| `openbao_seal_key` | unseal passphrase (≥ 32 chars); unrecoverable — password manager |
| `openbao_seal_previous_key` | only during a seal rotation |
| `openbao_oidc_client_id`, `openbao_oidc_client_secret` | OIDC client (Casdoor registers it with these values; for another IdP, copy them from there) |

## Operations

| Task file | Purpose |
|---|---|
| `tasks/status.yml` [`make openbao-status`] | seal state, version, mounts, auth methods, the *effective* bound claims of each sign-in role (a wrong claim key admits nobody and raises no error), whether a recovery key is still on the host. Never prints the token or the key. |
| `tasks/backup.yml` [`make openbao-backup`] | raft snapshot into `openbao_backup_dir` (root-only), verified as a gzip archive (a failed request can leave an error document that only looks like a backup), the root token copied alongside, newest `openbao_backup_keep` kept. Not part of convergence. |
| `journalctl -u openbao` [`make openbao-logs`] | server and audit log |

**What a backup does not contain:** the seal passphrase — on purpose; a backup that carries its
own key is not encrypted. Restore: start a store with the same `openbao_seal_key`, then
`curl -X POST -H "X-Vault-Token: <its root token>" --data-binary @openbao-….snap
http://127.0.0.1:8200/v1/sys/storage/raft/snapshot`; afterwards the root token is the one saved
with the snapshot. A snapshot refuses to load under a different seal key (`snapshot-force` skips
the check but the data still cannot be decrypted). Not yet rehearsed: do it once on a test host
before relying on it.

Writing application secrets is not a make target on purpose: the value would have to pass
through `secrets.yml` or a command line. People use the UI or `bao` after signing in.

## Pitfalls this role handles

- **Image user**: the image runs as uid 100 / gid 1000; the raft directory belongs to them (a
  root-owned one crash-loops on the first write). The configuration is mounted as a single file
  into the image's own `/openbao/config`, which stays the image user's — the entrypoint would
  otherwise try to chown a read-only mount.
- **`BAO_ADDR=http://127.0.0.1:8200`** in the container: the client defaults to https, and the
  health check (`bao status`) would report a healthy server as broken.
- **No `Notify=healthy`**: before the first initialisation the server is never healthy, so the
  unit would time out before the role could initialise it.
- **Audit devices are configuration-only in 2.7** (the API refuses them).
- **`bound_claims` is built as one expression**: Ansible templates dict values but not keys, so
  `"{{ claim }}": [...]` would send the literal braces as the claim name — a role that matches
  nobody and fails closed silently.
- **Upgrade tripwire**: 2.7 moved most auto-unseal mechanisms into plugins; static and transit
  stayed built in. Check the seal and storage types against the release notes of every minor.
