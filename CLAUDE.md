# onebox — rules for anyone (human or agent) changing this repo

onebox is a **reference platform**: one host per environment runs an internal service
platform (edge TLS, Git forge, SSO, secrets, datastores, Kubernetes + GitOps). It is meant
to be reused in many environments, so **every rule below exists to keep it generic**.
Architecture: [ARCHITECTURE.md](ARCHITECTURE.md). Operator guide: [README.md](README.md).
Why things are the way they are: [docs/adr/](docs/adr/).

## 1. Generic first

- **No environment facts in roles.** Domains, IPs, CIDRs, user names, org names, cloud
  accounts live only in `inventories/<env>/`. Roles ship neutral defaults
  (`example.com`, `192.0.2.10`, `CHANGE-ME`).
- **Everything optional is a component.** `onebox_components` (list) selects what runs;
  `roles/preflight` validates dependencies between components and that required secrets
  are filled. A role that is not listed must not touch the host.
- **Providers are variables, not forks.** OS family (RedHat/Debian), firewall backend
  (`firewalld`/`none`), TLS mode (`acme_dns`/`acme_http`/`internal`/`files`), DNS provider
  (`route53`/`cloudflare`/`rfc2136`/…), OIDC issuer (Casdoor or any OIDC IdP) are chosen in
  the inventory. Adding a provider = adding a branch to a lookup table, never a copy of a role.
- **ansible-core only.** Use `ansible.builtin.*` modules; no Galaxy collections. The platform
  must deploy from distro packages on an offline-ish host. Write the FQCN every time.

## 2. Layers and contracts

```
make (humans) → deploy.sh (source of truth, bash only) → ansible-playbook site.yml
```

- Humans only ever run `make <target>`. If you would ask someone to run a raw command twice,
  add a target instead (to `deploy.sh` and `Makefile`).
- **Edge contract** (the only one): `caddy_edge` owns 80/443 and all TLS; it imports
  `/etc/caddy/conf.d/*.caddy`. Every service ships exactly one drop-in through `caddy_vhost`
  with `reverse_proxy 127.0.0.1:<port>` and **no `tls` block**. Nothing edits the main Caddyfile.
- **Ports**: containers publish on `127.0.0.1` only. Firewall rules on INPUT do not protect
  published container ports or NodePorts (they are DNAT/FORWARD) — loopback binding is the
  real protection. Exceptions (git-over-SSH, datastores for pods) must be explicit variables.
- **Containers**: rootful podman + Quadlet units in `/etc/containers/systemd/`. Generic
  services use `podman_quadlet`; only services with unusual needs ship their own unit template.
  The edge proxy and the CI runner are **not** containerised (see ADRs).
- **Data**: shared datastores live on the private `onebox-data` podman network. An app that
  needs a database creates its own role/database in its own role; `datastores` only owns
  superusers.

## 3. Role layout

```
roles/<role>/
  defaults/main.yml   every variable, prefixed with the role name, documented inline
  tasks/main.yml      entry point; includes render.yml first
  tasks/render.yml    ONLY tasks that write files (template/copy/file state=directory)
  handlers/main.yml   every handler guarded with `when: not onebox_render_only`
  templates/ files/ README.md
```

- **Render mode** is how this repo is tested without a VM. In `tasks/render.yml` every path
  is prefixed with `{{ onebox_root }}` and ownership uses `{{ onebox_owner }}` /
  `{{ onebox_group }}` (they become `omit` in render mode). `tests/render.yml` runs every
  role's `render.yml` against `tests/inventory` and the validators check the output.
- Templates must not read `ansible_facts` directly; use `onebox_*` variables (facts are not
  gathered in render mode). OS-specific values come from `roles/common/vars/<family>.yml`.
- Tasks that only read state use `changed_when: false` and `check_mode: false`.
- Pin every image and download by version **and** checksum/digest when the upstream publishes one.

## 4. Secrets

- Plain secrets live only in `inventories/<env>/group_vars/onebox/secrets.yml` (gitignored);
  `inventories/example/secrets.example.yml` lists every key with a `CHANGE-ME…` value.
  Optional `ansible-vault` encryption is supported (`VAULT=1`).
- Tasks whose arguments contain a secret value use `no_log: true`.
- `assert` tasks **never** use `no_log` (it hides `fail_msg`). Their `that:` and `fail_msg`
  must not interpolate secret values, and `loop` items must not contain secrets.
- Edit secrets with `make secrets-gen|secrets-set|secrets-show KEY=…`, never with `sed`.

## 5. Checks before every commit

`make test` must be green: shellcheck, yamllint, ansible-lint, `--syntax-check`, template
rendering, `podman` Quadlet dry-run, `caddy validate`, `kubeconform`. Red means no commit.

## 6. Git

Conventional Commits in **English**: `type(scope): imperative summary`, scope = role or area
(`edge`, `gitlab`, `k3s`, `make`, `tests`, `docs`, `repo`). Types: feat, fix, refactor, docs,
test, chore, build, ci. Linear history only.
