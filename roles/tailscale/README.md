# tailscale — remote access without an inbound port

Joins the host to a Tailscale tailnet so people outside the LAN reach the platform over
WireGuard. The host only dials out: no port forwarding, no service exposed to the internet.
The coordination server (Tailscale SaaS, or a self-hosted one through
`tailscale_extra_up_args: ["--login-server=…"]`) never sees traffic in clear: relays forward
ciphertext and private keys stay on the devices.

```
laptop at home ──WireGuard──▶ tailscale0 on the host
                               ├─▶ <onebox_host_ip>:443  edge → every vhost (same names, same certificates)
                               └─▶ <onebox_host_ip>:22   git over SSH (when gitlab_ssh_enabled)
```

## Variables

| Variable | Default | Meaning |
|---|---|---|
| `tailscale_version` | pinned | package version (official repository, signing key pinned) |
| `tailscale_hostname` | `onebox-<env>` | machine name in the tailnet |
| `tailscale_advertise_routes` | `[<onebox_host_ip>/32]` | subnet routes offered to the tailnet |
| `tailscale_advertise_tags` | `[]` | ACL tags requested at join (`tag:onebox`) |
| `tailscale_advertise_exit_node` | `false` | act as exit node |
| `tailscale_accept_routes` | `false` | use routes other nodes advertise |
| `tailscale_accept_dns` | `false` | let MagicDNS manage the host's resolver |
| `tailscale_ssh` | `false` | Tailscale SSH server |
| `tailscale_firewalld_zone` | `public` | zone of `tailscale0` (with firewalld) |
| `tailscale_extra_up_args` | `[]` | extra `tailscale up` arguments at join |
| `tailscale_repo_distro` / `_codename` / `_el_major` | from facts | repository coordinates |

Secret: `tailscale_auth_key` — needed only while the node is not in a tailnet yet.

## Contracts

- **The edge lets tailnet clients in.** Peers arrive with their tailnet address
  (100.64.0.0/10) as source; with this component enabled that range joins
  `onebox_internal_cidrs`, so internal-only vhosts answer them instead of 403.
- Runs before the edge in `site.yml`. A failure here (e.g. a missing auth key on a node that
  must still join) stops the later plays for this host, so drop `tailscale` from
  `onebox_components` instead of leaving a placeholder key.

## Why it is built like this

**Only the host's own /32 is advertised.** Advertising the whole LAN would hand the tailnet
everything on it, including what no host firewall can filter: published container ports
and Kubernetes NodePorts are DNAT'ed, they never pass the INPUT chain. With the host's /32,
tailnet peers reach exactly this host, and nothing else changes: the existing DNS names
already point at this address, the certificates and vhosts stay as they are. Traffic to the
host's own address is delivered locally, so no IP forwarding is needed; the role only
enables forwarding (sysctl drop-in) when another route or the exit-node role asks for it.

**`tailscale0` goes into the `public` firewalld zone,** the zone that already admits only the
edge ports and admin SSH: a tailnet peer gets what a LAN client gets. `trusted` would open
every local port to the whole tailnet; preflight refuses it.

**Everything that widens the node's role is off**: exit node (the tailnet's internet traffic
through this host), accepting routes (this node is reached, it does not reach into other
subnets), MagicDNS (would rewrite the host's resolver), Tailscale SSH (bypasses sshd — its
keys, its logs, the break-glass `DenyUsers`).

**The auth key is needed once.** Auth keys expire; a node that already joined must keep
converging without one. So the key is asserted only while the node is logged out, handed to
`tailscale up` as `--auth-key=file:/run/…` (a 0600 file deleted right after) — on the command
line it would be visible in the process list to every local user, CI jobs included.
`tailscale up` gets `--timeout`, so a bad key fails instead of waiting forever for an
interactive login.

**Preferences converge, tags do not.** Routes, DNS, SSH, exit node and hostname are compared
with `tailscale debug prefs` and corrected with `tailscale set`. That command is a debug
interface without a format promise: if it cannot be parsed, the settings are applied anyway
rather than silently skipped. Tags can only change through a new `tailscale up`, which the
coordination server may answer with a re-authentication prompt — the role reports a
difference instead of triggering that unattended.

**Install from the official repository, key pinned.** The repository definition is a rendered
file (testable, visible in `--diff`); the signing key is downloaded with a SHA-256 checksum
and, on RPM systems, imported with its fingerprint checked. A repository file left by
Tailscale's install script with a different `Signed-By` is removed (apt refuses two
definitions of one repository with different keys).

## Outside this repository (admin console)

1. **Approve the advertised route** (Machines → this host → Edit route settings), or let an
   `autoApprovers` ACL do it. Until then clients get no route and nothing on the host shows
   why.
2. **ACLs**: restrict who reaches the host and on which ports (443, and 22 for git); the
   default policy lets every member reach everything.
3. **Tailnet Lock**: new nodes must be signed by a trusted node, so the coordination server
   alone cannot add a device. Add your people first, then enable it — or every new device
   needs a signature before it can connect.
4. **Key expiry** stays on. People leaving are removed in the admin console (with a SaaS
   identity provider other than your own directory, nothing removes them automatically).
5. **Linux clients** must run `tailscale up --accept-routes`; other platforms accept routes
   by default. Without it `tailscale status` looks perfect and the browser times out.

## Operations

```bash
sudo make tailscale                       # install, join, converge preferences
tailscale status; tailscale debug prefs   # state of the node
```

Generate an auth key for joining: admin console → Settings → Keys → Generate auth key
(not reusable, not ephemeral; pre-approved and tagged if your ACLs use tags), then
`make secrets-set KEY=tailscale_auth_key`.

**Uninstall** (e.g. moving to another overlay network):

```bash
ansible-playbook -i inventories/<env> playbooks/tailscale-uninstall.yml                                   # preview
ansible-playbook -i inventories/<env> playbooks/tailscale-uninstall.yml -e tailscale_uninstall_confirm=true  # remove
```

Suggested targets: `make tailscale-uninstall` / `make tailscale-uninstall-confirm`. It logs
out first (otherwise a ghost machine stays in the admin console, its node key still trusted
and counted against the device quota), removes the package, repository, key and
`/var/lib/tailscale` (otherwise a reinstall comes back with the old identity) and unbinds
`tailscale0` from firewalld. It refuses to run while an SSH session reaches the host through
the tailnet — that session would be cut half-way. Afterwards: remove `tailscale` from
`onebox_components` and `100.64.0.0/10` from the LAN CIDRs, delete the machine in the admin
console, drop `tailscale_auth_key` from secrets.yml.

## Pitfalls

- **`--check` on a host without Tailscale** cannot know the package: the repository file is
  not really written in a dry run. The role says so and skips the rest instead of failing
  (a failure here would also hide every later play from `make check`).
- **Verifying from outside**: phone off Wi-Fi, open `https://gitlab.<domain>` — a timeout
  means no route (approval, `--accept-routes`), a 403 means the edge does not admit
  100.64.0.0/10.
