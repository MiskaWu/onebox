# roles/datastores — shared PostgreSQL, MySQL, Redis, NATS, etcd

Shared engines for every service and workload on the host, as Quadlet containers on the private
podman network `onebox_data_network` (`onebox-data`, fixed subnet `onebox_data_subnet`). This
role owns the engines and their superusers; a service that needs a database gets its own role
and database — declared here for workloads without a role of their own (Kubernetes apps), or
created by the service's role (casdoor does). Why shared, why fixed addresses, why no LAN ports:
[ADR 0011](../../docs/adr/0011-shared-datastores-app-owned-databases.md),
[ADR 0012](../../docs/adr/0012-datastore-reachability.md).

Component: `datastores` (no dependencies).

## Engines

| Engine | Switch (default) | Container / DNS name | Data-network address | Host port (`127.0.0.1`) | Data |
|---|---|---|---|---|---|
| PostgreSQL 18 | `datastores_postgres_enabled` (on) | `postgres` | subnet + 201 | 5432 | `<data_root>/postgres` |
| Redis 8 cluster, 3 masters | `datastores_redis_enabled` (on) | `redis-0` … `redis-2` | subnet + 211 … 213 | 6379, 6380, 6381 | `<data_root>/redis-<n>` |
| MySQL 9.7 LTS | `datastores_mysql_enabled` (off) | `mysql` | subnet + 202 | 3306 | `<data_root>/mysql` |
| NATS 2.14 | `datastores_nats_enabled` (off) | `nats` | subnet + 203 | 4222 | `<data_root>/nats` (JetStream only) |
| etcd 3.6 | `datastores_etcd_enabled` (off) | `etcd` | subnet + 204 | 2379 | `<data_root>/etcd` |

`<data_root>` is `datastores_data_root` (`/var/lib/onebox/datastores`). Images are pinned by tag
and index digest in `defaults/main.yml`, with the reason for each line choice next to it.
Switching an engine off stops its container and removes its unit and podman secrets on the next
converge; its data directory stays (deleting data is a separate decision).

**Host paths, not named volumes:** the `storage` component can mount a disk or LV at
`/var/lib/onebox`, and backups see plain directories. Each directory belongs to the user the
image runs as (`datastores_*_uid`, verified against the pinned images; re-check on bumps). Quadlet
adds `RequiresMountsFor=` for every bind source, so when that path is a mount that did not come
up, the engines stay down instead of initialising empty databases on the root filesystem.

## Connecting

1. **Containers** join the network (`podman_quadlet_networks: [onebox-data.network]`) and use
   the container name: `postgres:5432`, `mysql:3306`, `nats:4222`, `etcd:2379`. Redis is the
   exception: cluster clients get node *addresses* in every redirect, so they start from one of
   `datastores_redis_ips` (any one; they discover the rest).
2. **Host tools and people** use `127.0.0.1`. From another machine, tunnel through the admin
   sshd: `ssh -p <admin port> -L 5432:127.0.0.1:5432 you@host`. Database GUIs keep the tunnel in
   the connection profile — use their *host + port* mode: URL modes are used verbatim and connect
   to the laptop's own localhost. For Redis, configure the GUI's SSH tunnel with a node's
   data-network address, not `127.0.0.1`: the host can route there, and cluster redirects name
   those addresses (with `127.0.0.1` it connects, lists keys, and fails on the first key in
   another slot).
3. **Kubernetes pods** route to the fixed data-network addresses (pod → CNI bridge → host →
   podman bridge) through a Service without a selector, so the application's DSN is the same
   string on podman and in the cluster (`postgres:5432`) and no address appears in its config:

   ```yaml
   apiVersion: v1
   kind: Service
   metadata: {name: postgres}
   spec:
     ports: [{name: postgres, port: 5432, targetPort: 5432}]
   ---
   apiVersion: discovery.k8s.io/v1
   kind: EndpointSlice
   metadata:
     name: postgres-1
     labels: {kubernetes.io/service-name: postgres}
   addressType: IPv4
   ports: [{name: postgres, port: 5432}]
   endpoints: [{addresses: ["10.89.10.201"]}]
   ```

   Argo CD skips `EndpointSlice` objects by default (an excluded kind shows Synced/Healthy and is
   never applied); the platform's Argo CD configuration allows it.

**LAN publishing is an explicit exception** (`datastores_<engine>_publish_lan`, off): it binds
`datastores_lan_address:<port>` as well. Know what that means before turning it on: a published
container port is DNAT'd in PREROUTING and travels the FORWARD path, so firewalld rules — which
live on INPUT — never see it, and with `ct status dnat accept` ahead of the zone rules a policy
cannot stop it either. The port is open to the whole LAN, in clear text, whatever the firewall
says; only the bind address protects a published port. Measure from another machine
(`nc -vz <host> 5432`), not with `firewall-cmd --list-all`. Redis has no LAN option: its
announced address also carries the cluster's own traffic.

## Authentication and secrets

Every engine requires authentication: pods can route to the data network, so "private network,
no password" does not hold. No password ever appears on a command line, in a unit file or in
Ansible output:

| Secret (`secrets.yml`) | Used by | Delivered as |
|---|---|---|
| `datastores_postgres_superuser_password` | `postgres` superuser | podman secret (env `POSTGRES_PASSWORD`) |
| `datastores_mysql_root_password` | MySQL `root` | podman secret (env `MYSQL_ROOT_PASSWORD`) |
| `datastores_redis_password` | `requirepass` + `masterauth`, all nodes | config file `<secrets_dir>/redis-<n>.conf` |
| `datastores_nats_password` | user `datastores_nats_user` | config file `<secrets_dir>/nats.conf` |
| `datastores_etcd_root_password` | etcd `root` user | stdin once; `<secrets_dir>/etcd-root.env` for admin calls |
| one key per `password_var` | application database owners | stdin (`podman exec -i`) |

`datastores_secrets_dir` (`/etc/onebox/datastores`) is root-only; each file in it belongs to the
container's user with mode 0400 and is bind-mounted read-only. The Redis password may only use
URL-safe characters (`make secrets-gen` produces those): it is written unquoted and read back
from the node's own file by operational commands. Everything else accepts any character.

**Rotation.** The images apply `POSTGRES_PASSWORD` / `MYSQL_ROOT_PASSWORD` only when they
initialise an empty data directory. For PostgreSQL the role closes that gap: it checks the
superuser and every owner password over TCP and sets them through the container's trusted unix
socket when they differ — change the secret, converge, done. MySQL root has no such path: change
it in MySQL first (`ALTER USER` for `root@%` and `root@localhost`), then in `secrets.yml`;
the role stops with that instruction if they disagree. Redis and NATS pick up a new password
from their file on the restart the change triggers. etcd: `etcdctl user passwd root`, then the
secret.

## Application databases

```yaml
datastores_postgres_databases:
  - name: shop_dev            # database
    owner: shop_dev           # login role, owns the database: no per-object grants needed
    password_var: shop_dev_db_password   # NAME of the secrets.yml key (values never in loops)
    createdb: false           # may the role create databases itself (opt-in)
datastores_mysql_databases:   # same shape; the owner gets ALL on its database
  - {name: legacy_dev, owner: legacy_dev, password_var: legacy_dev_db_password}
```

Created idempotently (database, role, ownership, password); tables are the application's job
(its migrations). Several databases can share an owner. Entries are never dropped by a converge
— removing a database is what the reset is for. Names are lowercase identifiers (validated,
because they end up in SQL). Suffix them with the environment (`<app>_<env>`): one instance may
serve several environments, and per-environment owners are the only isolation there is.

## Redis cluster

One master per address, no replicas. On one host that buys no availability; it buys protocol
parity with a real cluster, which applications must honour from day one:

- database 0 only (`SELECT` fails);
- multi-key commands, Lua and `MULTI` across slots need hash tags: `user:{42}:profile`;
- cluster-aware clients (redis-py `RedisCluster`, ioredis `Cluster`, go-redis
  `ClusterClient`); `redis-cli -c` follows redirects;
- `maxmemory` is per node (`datastores_redis_maxmemory`): the cluster may use n × that.

**Formation** happens once, when every node still knows only itself (`cluster_known_nodes:1`).
Not `cluster_state:ok`: a degraded cluster reports `fail` too, and creating again would stop at
"Node is not empty". A half-formed cluster stops the converge at "Wait for the cluster to be
complete" on purpose; inspect and repair by hand:
`podman exec -it redis-0 sh -c 'REDISCLI_AUTH="$(awk '"'"'$1=="requirepass"{print $2}'"'"' /etc/redis/redis.conf)" redis-cli --cluster check <node address>:6379'` (then `--cluster fix`).

**The cluster bus is authenticated with TLS.** Port 16379 speaks the cluster protocol without
any password: a host that reaches it can `MEET` the cluster and have its gossip trusted — and
pods can reach the data network. The role creates a CA that signs only these nodes
(`<secrets_dir>/redis-tls/`, EC P-256, ten years, never rotated by accident), turns on
`tls-cluster`, and sets `cluster-bus-port-protected-mode yes` so a node refuses to start with an
unauthenticated bus. Clients keep plain TCP on 6379. Renewal: delete `redis-tls/` and converge
(all nodes restart; the converge warns 90 days ahead).

**Changing the size:** adding addresses to `datastores_redis_ips` starts new, empty nodes outside
the cluster (the converge says so). Joining them is deliberate: `redis-cli --cluster add-node
<new>:6379 <existing>:6379`, then `--cluster reshard`. Removing a node: move its slots away
first (`reshard`), `--cluster del-node`, then shorten the list.

## NATS and etcd

**NATS** replaces the image's default configuration, which enables clustering with a well-known
route password. JetStream (`datastores_nats_jetstream`) gets explicit memory and file limits:
there are no command-line flags for them, and without them it claims most of the host.

**etcd** runs a single member with role-based auth on (`datastores_etcd_auth_enabled`; turning
it off later runs `auth disable`, turning it on again re-enables). The image is distroless —
no shell — so every call is argv, and admin calls read `ETCDCTL_USER` from the root-only env file
(`podman exec --env-file`). Periodic compaction keeps history from filling the backend quota;
the corruption checks use 3.6's feature-gate form (3.7 drops the old flags). The advertised
client URL is the fixed address: clients that sync the member list would otherwise receive a
container name they cannot resolve. With auth on there is no container health check — an
anonymous health probe is refused ("user name is empty") and the role does not put
credentials into a unit file.

## Health

Each container has a health check that connects over TCP (`pg_isready -h 127.0.0.1`,
`mysqladmin ping`, `redis-cli ping`, NATS `/healthz`): during first initialisation PostgreSQL
and MySQL run a temporary server without networking, so "healthy" only turns true for the real
one. With podman ≥ 5.0 the units use `Notify=healthy` — the unit counts as started once
healthy, so dependants (casdoor) never race the database at boot. Ubuntu 24.04 ships podman 4.9;
`datastores_notify_healthy: auto` reads the version on the host.

## Operations

These task files back operator targets (wire them as playbooks; suggested names in brackets):

| Task file | Purpose |
|---|---|
| `tasks/status.yml` [`make datastores-status`] | unit states, PostgreSQL databases and *who is connected from where* (`pg_stat_activity`: the only reliable answer to "is everyone using the tunnel?"), Redis cluster state, etcd endpoint status, NATS health. Says "UNREADABLE" instead of empty when a probe fails. |
| `tasks/reset.yml` [`make datastores-reset` / `datastores-reset-confirm`] | Preview by default; with `datastores_reset_confirm=true` wipes all application data in every enabled engine and recreates the declared databases empty. |

**Reset model — protect list, not delete list** (ADR 0009): everything is wiped except what
`datastores_reset_protect_postgres` / `_mysql` name (system databases and the identity provider's
`casdoor` database — wiping that locks everyone out of every service). New, undeclared databases
are wiped by default, so forgetting costs a rebuild of reproducible data, never stale state
nobody notices. All engines go together: a cache or registry pointing at deleted rows is worse
than everything dirty. Engine details: `DROP DATABASE … WITH (FORCE)` because crash-looping apps
reconnect constantly; `FLUSHALL` on every Redis node because each master holds only its slots;
NATS restarts (dropping subscriptions) and loses its JetStream store when enabled. Workloads are
not restarted from here.

## Pitfalls this role handles (and why)

- **PostgreSQL 18 moved its data path** to `/var/lib/postgresql/<major>/docker` and refuses to
  start when something is mounted at the old `/var/lib/postgresql/data`: the mount point is
  `/var/lib/postgresql` and follows the major version (`vars/main.yml`).
- **Ownership of bind mounts**: a root-owned 0700 mount point lets the entrypoint create the data
  directory and then locks the engine out of its parent. Directories belong to the image's user;
  the group stays root because the entrypoints only ever fix the owner — convergence and images
  never take turns changing it.
- **`127.0.0.1` inside the PostgreSQL container is `trust`**: a password check there accepts
  anything. Checks connect to the container's own name (scram-sha-256). Published ports arrive
  from the bridge gateway, not loopback, so the host's `127.0.0.1:5432` is password-protected.
- **Port arithmetic**: node n publishes `datastores_redis_port + n` with both operands cast — a
  string port would turn `6379 + 1` into `63791` without an error.
- **Config files are bind-mounted**, invisible to the unit's change detection: handlers restart
  the engine, and the role flushes them before talking to it.
- **Fixed addresses are validated** in preflight (inside the subnet, not network/gateway/
  broadcast, unique): a wrong address creates a container just fine, and an EndpointSlice
  pointing at it times out far from the cause.

## Variables

All in `defaults/main.yml`, documented inline. Cross-role: `onebox_data_network`,
`onebox_data_subnet`, `onebox_host_ip` (group_vars). Other roles rely on the container names
(`postgres`, …) and on the PostgreSQL superuser being `postgres`.
