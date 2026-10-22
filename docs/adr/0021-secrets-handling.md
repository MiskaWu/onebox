# 0021. Secrets handling rules

- Status: Accepted
- Related: [0003](0003-make-is-the-operator-interface.md), [0010](0010-podman-quadlet-services.md), [0013](0013-personal-operator-accounts.md), [0017](0017-openbao-and-external-secrets.md), [0025](0025-off-host-copies.md)

## Context

Ansible prints a lot: task arguments, loop items, assertion text, `--diff` output. Each is a
path for a secret to reach a terminal, a CI log or a shared screen. The opposite mistake —
hiding too much — makes the one message an operator needs on a first deploy invisible.

## Decision

- **Where secrets live:** `inventories/<env>/group_vars/onebox/secrets.yml`, gitignored,
  optionally encrypted with ansible-vault (`VAULT=1`). `secrets.example.yml` lists every key with
  a `CHANGE-ME…` value. Preflight refuses to deploy a component while one of its keys still holds
  a placeholder; converging a single component checks only that component's keys, so one service
  can be deployed while another's secrets are still pending.
- **Editing:** `make secrets-gen|secrets-set|secrets-show|secrets-missing KEY=…`. A script edits
  the YAML (values containing `& | \ "` break `sed`); `secrets-set` reads without echo or shell
  history; targets that write refuse to run as root.
- **`no_log: true`** on every task whose *arguments* contain a secret value: rendering env files
  and configuration files with credentials, creating podman secrets, comparing secret-derived
  values.
- **`assert` never uses `no_log`:** on failure, `no_log` replaces the whole result — including
  `fail_msg` — with "censored", which hides exactly the message the operator needs. A failing
  assert prints the expression *as written* and the `fail_msg`, not evaluated values, so it is
  safe as long as:
  - `that:` and `fail_msg` never interpolate a secret (write `"x is not match('CHANGE-ME')"`, not a
    string concatenated with the value);
  - **loop items never contain secrets.** A *successful* assert prints every item into the
    result; `loop_control.label` only changes the header line. Loop over variable *names* and
    read values with `lookup('ansible.builtin.vars', item)`.
- **Delivery to processes:** podman secrets, `EnvironmentFile=` with mode 0600, or stdin — never
  command lines, world-readable units or `Environment=` ([0010](0010-podman-quadlet-services.md)).
- **Platform secrets stay out of the platform's own secrets store** ([0017](0017-openbao-and-external-secrets.md)).

## Consequences

- Placeholders fail loudly and early with an actionable message; values never appear in output.
- Threat model, stated plainly: at-rest encryption protects the repository, its history, backups
  and people without root — not against current operators, who can read rendered configuration
  at runtime. Offboarding therefore rotates the secrets themselves
  ([0013](0013-personal-operator-accounts.md)).
- ansible-vault derives its key with PBKDF2-SHA256 at 10,000 iterations — far below current
  guidance for that construction. Its strength collapses to the vault password's entropy: a
  memorable password is effectively no encryption once the file is public; a random 25+
  character password from a password manager is out of reach. Once ciphertext is in Git, attacks
  are offline and history is permanent: a leaked vault password exposes every past commit, so
  rotation means rotating the secrets, not just the vault password.
- What the secrets file is really for: most keys are random values that could be regenerated —
  the need is that they stay *consistent* across deployments (they are already baked into data
  volumes) and that they *survive* the host. The external credentials (DNS API) and the
  unrecoverable keys (the secrets store's seal key) are the critical ones
  ([0025](0025-off-host-copies.md)).

## Alternatives considered

- **SOPS with age:** no password-derived key to brute-force; costs two extra binaries and moves
  the problem to backing up the age private key.
- **`no_log` everywhere:** hides failure messages; operators then work around it by printing
  values.
- **Platform secrets in OpenBao:** a bootstrap loop.

## Revisit when

- Encrypted secrets move into version control ([0025](0025-off-host-copies.md)): split the
  `.gitignore` rule into "plaintext forbidden" and "ciphertext allowed", and add secret scanning
  in pre-commit and CI.
