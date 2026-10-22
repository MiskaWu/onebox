# gitlab — the Git forge

GitLab CE from the official omnibus image, as a rootful Quadlet container (`gitlab.service`)
with its own unit template, behind the edge proxy:

```
client ──https──▶ edge (Caddy, TLS) ──http──▶ 127.0.0.1:8081   GitLab (bundled nginx → workhorse → puma)
client ──https──▶ edge ──http──▶ 127.0.0.1:5050                container registry (optional)
client ──ssh────────────────────▶ <onebox_host_ip>:22          git over SSH (optional, default off)
```

It brings its own PostgreSQL and Redis (the configuration GitLab tests most) and does not use
the `datastores` component. The CI runner is a separate component (`gitlab-runner`).

## Variables

All documented in `defaults/main.yml`. The main groups:

| Group | Variables |
|---|---|
| image | `gitlab_image`, `gitlab_version`, `gitlab_image_digest` (pinned tag + digest) |
| storage | `gitlab_data_root` (`/srv/gitlab`), `gitlab_shared_dir`, `gitlab_backup_dir`, `gitlab_required_mounts` |
| HTTP | `gitlab_http_port`, `gitlab_trusted_proxies`, `gitlab_vhost_entries` |
| registry | `gitlab_registry_enabled`, `gitlab_registry_port` (hostname: `gitlab_registry_hostname`) |
| SSH | `gitlab_ssh_enabled` (false), `gitlab_ssh_port`, `gitlab_ssh_bind_address` |
| sign-in | `gitlab_oidc_enabled` (on when `onebox_oidc_issuer` is set), `gitlab_oidc_label`, `gitlab_oidc_auto_sign_in`, `gitlab_oidc_block_auto_created_users`, `gitlab_oidc_client_auth_method`, `gitlab_trusted_ca_files` |
| mail | `gitlab_smtp_enabled`, `gitlab_smtp_host`, `_port`, `_tls`, `_authentication`, `gitlab_email_from`, … |
| resources | `gitlab_shm_size`, `gitlab_puma_workers`, `gitlab_sidekiq_concurrency`, `gitlab_bundled_monitoring`, `gitlab_kas_enabled`, `gitlab_malloc_conf`, `gitlab_rb_extra` |
| backups | `gitlab_backup_keep_time`, `gitlab_backup_schedule`, `gitlab_backup_skip` |

Secrets (secrets.yml): `gitlab_root_password`; `gitlab_oidc_client_id` and
`gitlab_oidc_client_secret` when OIDC is on; `gitlab_smtp_user` and `gitlab_smtp_password`
when SMTP uses authentication.

## Contracts

- **Edge**: `gitlab_vhost_entries` — GitLab on `gitlab_hostname`, the registry on
  `gitlab_registry_hostname` (not on the portal). Both retry for 30 s while GitLab restarts
  instead of answering 502, and WebSockets survive edge reloads.
- **OIDC**: the client is `onebox_oidc_clients.gitlab` (redirect
  `https://<gitlab_hostname>/users/auth/openid_connect/callback`); Casdoor creates it when
  it is a component, any other provider needs it registered by hand.
- **Ordering**: `common` (admin sshd move) before `gitlab` when `gitlab_ssh_enabled`;
  `storage` before `gitlab` when the data lives on volumes of its own.

## Why it is built like this

**Configuration: a mounted `gitlab.rb`, secrets in separate files.** The image also accepts
the whole configuration in the `GITLAB_OMNIBUS_CONFIG` environment variable. Not used: Ruby
inside an environment variable is an escaping minefield; the environment of a container is
visible to `podman inspect`, in `/proc/<pid>/environ` and inherited by every process
inside; and it cannot be reviewed as a diff. Instead `gitlab.rb` is rendered into the config
volume and contains **no secret at all** — it stays readable in `make check --diff`. Every
secret is a root-only file in `config/onebox-secrets/` (written with `no_log`), and
`gitlab.rb` reads it when reconfigure runs (`File.read`, documented by GitLab for this
purpose). Files of features that are switched off are removed. Values from the inventory
are written as Ruby single-quoted strings, so nothing in them is ever interpolated.

**Applying changes.** A changed `gitlab.rb` or secret is applied with
`gitlab-ctl reconfigure` inside the running container (seconds of disruption, not a
restart); a changed unit or image restarts the container (the image reconfigures on every
start). The role then waits until GitLab answers — the first start initialises the database
and takes minutes (`gitlab_start_timeout`). The image (about 1.5 GB) is pulled by the role
before the service starts, so a slow download cannot run into the unit's start timeout.

**TLS ends at the edge.** The bundled nginx listens on plain HTTP and is told the original
scheme (`X-Forwarded-Proto: https`); Let's Encrypt inside the container is switched off —
with an `https://` external URL omnibus would otherwise try to obtain a certificate itself.
The client address comes from `X-Forwarded-For`, believed only from loopback and the podman
bridge (connections to a published port arrive from its gateway).

**Git over SSH is opt-in.** SSH has no SNI: a client sends no host name before the handshake,
so neither the edge nor any other proxy can split one address's port 22 between the host's
admin sshd and GitLab. With `gitlab_ssh_enabled`, GitLab takes 22 on
`gitlab_ssh_bind_address` and the admin sshd has to live elsewhere: preflight asserts
`common_admin_ssh_port != gitlab_ssh_port`, and before starting the container the role checks
that sshd really released the port (roles/common keeps the old port open while someone is
connected through it). The published port is DNAT: firewall rules on INPUT do not filter it,
so it is reachable from wherever the host address is — gitlab-shell accepts keys only.
`gitlab_shell_ssh_port` (clone URLs) and the published port come from the same variable and
cannot disagree.

**Storage: hot data on its own volume, cold blobs where you like.** Repositories, the
database and uploads are random-I/O hot data: put `gitlab_data_root` on a fast volume of its
own (roles/storage), so GitLab filling it cannot fill the OS. `gitlab_shared_dir` (LFS,
artifacts, packages, registry blobs) and `gitlab_backup_dir` are mounted *inside* the data
volume, so big cold data and backups can sit on other disks without changing any GitLab path
setting (relocating GitLab paths in `gitlab.rb` has sharp edges: repository paths must not be
symlinks, `git_data_dirs` is gone since 18.0). Podman orders nested mounts by depth. Two
guards:
- `RequiresMountsFor=` in the unit: at boot, a volume that failed to mount keeps GitLab down
  — instead of GitLab initialising a fresh, empty instance in the directory underneath (and
  later "losing" it when the volume is back). `gitlab_required_mounts` adds a deploy-time
  check.
- A nested mount *hides* what was in the directory before. Pointing `gitlab_shared_dir` at an
  empty disk while LFS objects still live in the data volume would make them vanish from
  GitLab's view; the role refuses and prints the copy command.

**LFS and object storage.** LFS objects, artifacts and registry blobs stay on the file
system. Object storage (S3, Garage, …) is the scale-out answer, but on one host it adds a
stateful service in the path of every LFS download, a less exercised code path in GitLab, and
a second thing to back up (the backup archive no longer contains the blobs). GitLab's
`gitlab:lfs:migrate`-style tasks move data to object storage later, online, if a real need
appears — this choice does not close that door.

**Directory permissions.** `gitlab_data_root` is `0700 root`. The volume directories under it
get no forced owner or mode: reconfigure sets its own on every start, and forcing ours would
fight it on every converge (usually loosening them). The parent is the guard.

**Memory on a shared host.** GitLab's defaults assume a dedicated machine. The defaults here
follow GitLab's memory-constrained guidance: fewer puma workers (0 = single process, 100–400
MB less), `sidekiq` concurrency 10, the bundled Prometheus stack off (~300 MB),
the Kubernetes agent server off (GitOps runs on Argo CD), jemalloc returning memory sooner.
`ShmSize` 256 MB: the container default of 64 MB is too small for GitLab's metrics files.

**Sign-in.** OIDC against `onebox_oidc_issuer` — Casdoor when it is a component, or any
OIDC provider (Keycloak, Entra ID, Google, …). New SSO users are blocked until an admin
approves them unless you set `gitlab_oidc_block_auto_created_users: false` — do that only
when the provider admits nobody but your organisation. `client_auth_method: query` sends the
secret in the request body (client_secret_post), which all of these accept. The `issuer`
must equal the `issuer` of the provider's discovery document byte for byte (a trailing slash
included). With `gitlab_oidc_auto_sign_in`, password sign-in is hidden, not removed:
`/users/sign_in?auto_sign_in=false` is the break-glass path for `root`. Before turning off
password sign-in altogether (an application setting), make sure an SSO account is an admin.

**Mail.** Without SMTP, omnibus falls back to `sendmail` — which the image does not contain.
Every mail (password resets, invitations, CSV exports) then fails in a background job with no
sign in the UI. So "no relay" here means mail is **disabled** (`gitlab_email_enabled = false`),
not silently lost. With a relay: STARTTLS (587) and implicit TLS (465) are mutually
exclusive settings — the wrong combination hangs. The sender domain must be accepted by the
relay (verified domain, SPF, DKIM); with many providers new accounts can only send to
verified recipients until you request production access, and SMTP credentials are often
not the account's API keys but derived ones. A relay can accept the login and still reject
the message (authorisation is checked at DATA time) — always send a test mail after
setting it up.

## Operations

| Suggested target | Command |
|---|---|
| `make gitlab-status` | `systemctl status gitlab`; `podman exec gitlab gitlab-ctl status` |
| `make gitlab-logs` | `podman logs -f gitlab` (or `podman exec -it gitlab gitlab-ctl tail`) |
| `make gitlab-backup` | `systemctl start gitlab-backup` (waits until done; `journalctl -u gitlab-backup`) |
| `make gitlab-mail-test TO=…` | `podman exec gitlab gitlab-rails runner "Notify.test_email('$TO', 'onebox mail test', 'It works.').deliver_now"` |
| `make gitlab-root-password` | `podman exec -it gitlab gitlab-rake "gitlab:password:reset[root]"` (interactive) |
| `make gitlab-reconfigure` | `podman exec gitlab gitlab-ctl reconfigure` |

**First start**: `sudo make gitlab`, wait (the role waits up to `gitlab_start_timeout`), sign
in as `root` with `gitlab_root_password`, change it. GitLab rejects a weak initial password
while seeding the database — and that aborts the whole reconfigure, so the container exits
and restarts in a loop. Below 64 characters it must not contain `gitlab`, `devops` or
anything from root's name, username or e-mail (`Administrator`, `root`, `admin@example.com`)
and must not be a common password; preflight checks the predictable part. Use
`make secrets-gen KEY=gitlab_root_password`. The value is used once, when the
database is created; later changes of the secret do nothing (use the reset command).
Then: create the instance runner (roles/gitlab_runner README); in Admin → Settings → CI/CD,
keep fork pipelines from running in parent projects; if git-over-SSH is off, set "Enabled Git
access protocols" to HTTP(S) only so the UI stops showing SSH URLs.

**Backups.** `gitlab-backup.service` writes two archives into the backup directory: the data
(`gitlab-backup create`, with `STRATEGY=copy` for a live instance) and, in `config/`, the
configuration (`gitlab-ctl backup-etc`: `gitlab.rb`, `gitlab-secrets.json`, the onebox
secret files). The data archive does **not** contain `gitlab-secrets.json` — without it a
restore cannot decrypt CI variables, two-factor secrets or runner tokens. Keep the
configuration archives apart from the data archives (they are the keys to them) and copy
both off the host. Archives older than `gitlab_backup_keep_time` are pruned. Restore (same
GitLab version): stop puma and sidekiq inside the container, `gitlab-backup restore
BACKUP=<timestamp>`, restore `/etc/gitlab` from the configuration archive, restart, then
`gitlab-rake gitlab:check SANITIZE=true`.

**Upgrades**: back up; check GitLab's upgrade path (required stops at x.2, x.5, x.8, x.11);
change `gitlab_version` and `gitlab_image_digest` (`podman manifest inspect` or the registry
API give the digest of the tag); `sudo make gitlab`; watch `make gitlab-logs` until the
migrations finish. Database migrations cannot be undone: the way back is the backup.

**Moving the data to its own volume** (GitLab already ran on the root file system): create
the volume with a temporary mount point (roles/storage), `systemctl stop gitlab`,
`cp -a /srv/gitlab/. /mnt/new/`, move `/srv/gitlab` aside, mount the volume at `/srv/gitlab`,
add it to `gitlab_required_mounts`, `sudo make gitlab`, check sign-in, clone and push, then
delete the old copy. Growing the volume later is an online `lvextend --resizefs`.

**Reclaiming LFS space**: deleting a project does not delete its LFS objects (they are
deduplicated across projects; only the link goes). GitLab's daily
`RemoveUnreferencedLfsObjectsWorker` removes objects nothing references. To run it now:
`podman exec gitlab gitlab-rails runner 'RemoveUnreferencedLfsObjectsWorker.new.perform'` —
at a quiet time: an LFS upload creates the object before linking it to the project, so an
upload in progress looks unreferenced for a moment.

## Private CAs

With `edge_tls_mode: internal` (or a corporate CA), GitLab inside its container does not
trust the edge's certificates — OIDC discovery against the issuer fails, and so do webhooks
to other vhosts. List the CA in `gitlab_trusted_ca_files` (for Caddy's internal CA:
`/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt`); it is copied to
`/etc/gitlab/trusted-certs/` and linked into GitLab's store on reconfigure. The runner needs
the same CA (`gitlab_runner_tls_ca_file`), and so does every git client.

Server-to-server calls through the edge (GitLab → the OIDC issuer when both run here) come
from the container's address, not from the LAN: a vhost that is LAN-only must also allow the
podman network (10.88.0.0/16) or GitLab gets 403 from its own identity provider.
