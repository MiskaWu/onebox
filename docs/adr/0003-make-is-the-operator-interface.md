# 0003. `make` is the only operator interface

- Status: Accepted
- Related: [0002](0002-ansible-core-only.md), [0009](0009-guarded-irreversible-changes.md), [0021](0021-secrets-handling.md)

## Context

Operators do not remember `ansible-playbook` flags, inventory paths or tag names. Every
hand-typed invocation is a chance to converge the wrong scope, the wrong environment, or as the
wrong user. `make` has its own sharp edges: it silently ignores variables nobody reads.

## Decision

- **Three layers:** `make` (humans) → `deploy.sh` (the source of truth; bash only; resolves the
  environment, installs ansible-core on bootstrap) → `ansible-playbook site.yml`.
- **Rule:** any command you would ask someone to run by hand a second time is a missing target.
  Add it to `deploy.sh` and the `Makefile` before asking.
- **Shape of the vocabulary:**
  - `make <component>` converges one component; the target name equals the play's tag;
  - `make <component>-<verb>` for operations on it (`status`, `logs`, `backup`, …);
  - `make check [TAGS=a,b]` is the dry run with diff; `make apply` converges everything;
    `make bootstrap` is the first run on a fresh host; `make test` runs the static checks
    without a host ([0024](0024-render-mode-static-testing.md)).
  - One verb per meaning and no synonyms or aliases. `test` means "make one real round trip
    that neither `check` nor `status` can answer" (a credential accepted by a registry, a mail
    actually delivered). Destructive operations come as a read-only preview `<op>` and an
    executing `<op>-confirm` ([0009](0009-guarded-irreversible-changes.md)).
- **Guards that encode the sharp edges:**
  - `TAGS=` is accepted only by `check`. Any other target refuses it, because make would
    otherwise ignore it and converge the whole host.
  - Targets that rewrite `secrets.yml` refuse to run as root; a root-owned secrets file can no
    longer be edited by its owner.
  - `deploy.sh` rejects unknown commands. It never falls through to "treat the word as a tag":
    a tag that matches nothing runs nothing and exits 0.
  - Prefer two targets over a flag: a mistyped flag is silently ignored by make, so
    `secrets-gen` and `secrets-set` are separate targets rather than `GEN=1`.
- **Full converge is `apply`:** accurate for the first run and the hundredth, and the verb of
  declarative tooling generally.

## Consequences

- Discoverable: `make help` is generated from the target comments and cannot drift.
- Accepted cost: preview and converge differ in shape (`make check TAGS=x` then `make x`), so
  a tired operator can preview one component and then type `make apply`. Mitigated by the
  `TAGS` guard and by help text that prints the two-step sequence.
- Accepted cost: every operation is added in two files.

## Alternatives considered

- **`make apply TAGS=x` for single components.** Symmetric with `check`, but each component has
  a family of operations (`gitlab-status`, `gitlab-logs`, `gitlab-backup`); moving the bare
  name into a parameter removes the head of the family. Supporting both spellings violates
  "no synonyms".
- **`install` as the full-converge verb.** Familiar from GNU make, but only accurate on the
  first run. The deeper lesson from that debate: if sibling repositories share an operator
  vocabulary, consistency between them matters more than which verb wins, and a rename is only
  a rename when both sides change at once. Old verbs get a hard-failing signpost, never an
  alias.
- **Documented raw commands.** Not remembered, not guarded, not consistent.

## Revisit when

- Components stop having operation families (unlikely: every service grows status, logs and
  backup).
- The repository must share its vocabulary with another one; then change both together.
