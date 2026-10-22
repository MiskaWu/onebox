# 0022. "Reported success, did nothing" is a named failure mode

- Status: Accepted
- Related: [0007](0007-host-firewall-scope.md), [0012](0012-datastore-reachability.md), [0015](0015-loopback-cluster-gateway.md), [0016](0016-gitops-central-repository.md), [0024](0024-render-mode-static-testing.md)

## Context

A failure that shouts gets fixed. A control that reports success while having no effect gets
written into documentation as fact. While building the platform this pattern appeared in
unrelated systems, always with the same shape:

- **Rule installed, not on the path.** firewalld accepted and listed source restrictions for
  container ports and NodePorts; DNAT'd traffic never reaches those rules
  ([0007](0007-host-firewall-scope.md)).
- **All lights green, object absent.** An Argo CD application showed Synced and Healthy while
  an EndpointSlice declared in Git did not exist, because the kind was excluded by default
  ([0012](0012-datastore-reachability.md)).
- **Detected, flagged, not acted on — and the status shows an older success.** With automated
  sync and no self-heal, Argo CD marked the object OutOfSync and then did nothing (the Git
  revision had not changed), while `.status.operationState` still reported the previous sync as
  successful.
- **No mail, no signal.** A forge container image without an MTA falls back to `sendmail`, every
  notification job fails with "file not found" and ends in the background-job dead set — password
  resets included — with nothing in the UI.
- **Disabled while "active".** A CI runner with a token from another instance gets 403, disables
  itself for an hour, and its service status stays active.
- **Configuration silently ignored.** Helm accepts values keys a chart does not use; a chart
  upgrade that moved keys leaves the old settings with no effect and no error.
- **Skip records read as "missing".** A loop task's `when` is evaluated per item; when a feature
  switch skips the probe, the registered results are skip records without output, and a
  downstream "if not found, add the rule" opened ports while the feature was off.
- **Diagnostics that lie.** A status script redirected stderr and fell back to "not found", so a
  *usage error* was reported as "the secret does not exist" and the following checks looped
  over nothing. A probe for "requires authentication" reported success because the client tool
  was not installed and the failure looked like a refusal.

## Decision

Treat every control as unverified until it is measured **from the side where the traffic or
data actually passes:**

- Firewall: read the real chain order (`nft list chain …`) or connect from another machine —
  not `firewall-cmd --list-all`, which only proves a rule exists.
- GitOps: compare rendered manifests with live objects; ask whether Argo CD knows the object at
  all (`.status.resources`), not whether the app is Synced. `operationState` describes the last
  operation, not the present.
- Connection paths: ask the server who is connected (`pg_stat_activity.client_addr`, `ss`), not
  the configuration.
- Mail: a target that sends a real message; a deploy-time assertion that a relay is configured.
- Charts: validate values against `values.schema.json` on every bump.
- Probes: check the tool exists; distinguish a usage error from an empty result (never
  `2>/dev/null || echo "none"`); diagnostics must still print a report under every failure
  (default values instead of exceptions, e.g. `(match or ['?']) | first`); a partial check says
  "only half verified", never "all passed".
- Feature switches on loops: repeat the guard on the task that acts.
- `--check` skips `command`/`shell` tasks and knows nothing about runtime behaviour; first
  deployments are verified live, and [0024](0024-render-mode-static-testing.md) covers what can
  be checked statically.
- Prefer designs that cannot report false success: bind instead of filter, derive instead of
  list, fail closed instead of defaulting open.

## Consequences

- More `status` and `test` targets, and each states what it does *not* verify.
- New instances are added to the list above: the list is the argument that this is a property
  of controls in general ("I executed" is not "I took effect"), not a quirk of one tool.

## Alternatives considered

Trusting tool output. That is how each instance above entered the documentation as fact.

## Revisit when

Not applicable — this is a criterion. Add instances when they occur.
