# Nessie + Iceberg + RustFS + Trino

A minimal, fully-local lakehouse stack. One `docker compose` command gives you an S3-compatible object store, a git-like Iceberg catalog, and a Trino SQL engine. Built as a learning sandbox for the open table / open catalog ecosystem.

```
   ┌──────────┐    SQL     ┌───────────────┐   catalog   ┌──────────┐
   │  client  │ ─────────▶ │     Trino     │ ──────────▶ │  Nessie  │
   └──────────┘            │  (Iceberg     │   REST      │ (branch/ │
                           │   connector)  │             │  commit) │
                           └──────┬────────┘             └─────┬────┘
                                  │ S3                         │ JDBC
                                  ▼                            ▼
                           ┌──────────────┐             ┌──────────────┐
                           │   RustFS     │             │  PostgreSQL  │
                           │ (S3 storage) │             │  (version    │
                           │  warehouse/  │             │   store)     │
                           └──────────────┘             └──────────────┘
```

## Components

| Service       | Image                                   | Role                                                           |
|---------------|-----------------------------------------|----------------------------------------------------------------|
| `rustfs`      | `rustfs/rustfs:latest`                  | S3-compatible object store — holds Iceberg data + metadata files |
| `rustfs-init` | `rustfs/rc:latest`                      | One-shot: creates the `warehouse` bucket on first boot         |
| `postgres`    | `postgres:18-alpine`                    | Durable version store for Nessie                               |
| `nessie`      | `ghcr.io/projectnessie/nessie:latest`   | Iceberg REST catalog with git-like branching / commits         |
| `trino`       | `trinodb/trino:latest`                  | MPP SQL engine with the Iceberg connector                      |

Everything runs on a single `lakehouse` bridge network. Table data persists in the `rustfs-data` volume; catalog state persists in `nessie-pg-data`.

## Security posture

For a learning stack, "secure" means **don't be reachable, don't ship default creds**:

- Credentials live in `.env` (gitignored). Copy `.env.example` → `.env` and change every value.
- Host ports are bound to `127.0.0.1` only — nothing is on your LAN. Postgres isn't published at all.
- Nessie's HTTP access log is off; healthcheck hits Quarkus' internal management port (`/q/health/ready` on 9000) so there's no log noise.
- Nessie API auth is unauthenticated (fine for localhost). For production, uncomment the OIDC env vars in `docker-compose.yml` and point them at your IdP.

## Quick start

```bash
git clone <this repo>
cd nessie-iceberg-stack
cp .env.example .env     # then edit it
docker compose up -d
```

Wait ~20s for everything to go healthy, then open a Trino shell:

```bash
docker exec -it trino trino
```

### Example: create a table and query it

```sql
trino> CREATE SCHEMA iceberg.demo WITH (location = 's3://warehouse/demo');
CREATE SCHEMA

trino> CREATE TABLE iceberg.demo.t (id int, name varchar);
CREATE TABLE

trino> INSERT INTO iceberg.demo.t VALUES (1, 'hi'), (2, 'there');
INSERT: 2 rows

trino> SELECT * FROM iceberg.demo.t ORDER BY id;
 id | name
----+-------
  1 | hi
  2 | there
(2 rows)
```

Tear down (keeping data): `docker compose down`
Nuke everything (volumes too): `docker compose down -v`

## Endpoints

| Service     | URL                              | Credentials       |
|-------------|----------------------------------|-------------------|
| Trino UI    | http://localhost:8080            | user: anything    |
| Nessie API  | http://localhost:19120/api/v2    | — (see note above)|
| RustFS S3   | http://localhost:9000            | from `.env`       |
| RustFS UI   | http://localhost:9001            | from `.env`       |

## Nessie: git-like data operations

The whole point of Nessie is making a data catalog behave like git — branches, commits, tags, merges, time travel across tables.

### Pattern: one Trino catalog per branch

Trino's Iceberg connector pins each catalog to one Nessie ref. So we ship two catalogs:

- `iceberg` → ref `main` (`trino/catalog/iceberg.properties`)
- `iceberg_dev` → ref `dev` (`trino/catalog/iceberg_dev.properties`)

To use another branch, drop in another `iceberg_<name>.properties` with the matching `iceberg.nessie-catalog.ref=<name>`.

Branch management (create / merge / delete / tag) happens through the Nessie REST API. The end-to-end demo lives in **`demo-branching.sh`** — the walkthrough below is what that script does.

### Walkthrough

Assume `iceberg.demo.t` has one row: `(1, 'hi')`.

**1. Create a `dev` branch from `main`'s current commit:**

```bash
MAIN_HASH=$(curl -s http://localhost:19120/api/v2/trees/main | jq -r .reference.hash)

curl -X POST "http://localhost:19120/api/v2/trees?name=dev&type=BRANCH" \
  -H "Content-Type: application/json" \
  -d "{\"type\":\"BRANCH\",\"name\":\"main\",\"hash\":\"$MAIN_HASH\"}"
```
Response:
```json
{ "reference": { "type": "BRANCH", "name": "dev", "hash": "a5013d4f..." } }
```

**2. Write on `dev` through the second Trino catalog:**

```sql
trino> INSERT INTO iceberg_dev.demo.t VALUES (2, 'from-dev-branch'), (3, 'another');
INSERT: 2 rows
```

**3. The two branches have diverged:**

```sql
trino> SELECT * FROM iceberg_dev.demo.t ORDER BY id;   -- dev
 id |      name
----+-----------------
  1 | hi
  2 | from-dev-branch
  3 | another

trino> SELECT * FROM iceberg.demo.t ORDER BY id;       -- main
 id | name
----+------
  1 | hi
```

**4. Merge `dev` → `main`** (v2 API uses `name@hash` as the optimistic-concurrency guard):

```bash
MAIN_HASH=$(curl -s http://localhost:19120/api/v2/trees/main | jq -r .reference.hash)
DEV_HASH=$(curl -s http://localhost:19120/api/v2/trees/dev  | jq -r .reference.hash)

curl -X POST "http://localhost:19120/api/v2/trees/main@$MAIN_HASH/history/merge" \
  -H "Content-Type: application/json" \
  -d "{\"fromRefName\":\"dev\",\"fromHash\":\"$DEV_HASH\"}"
```
Response:
```json
{
  "wasApplied": true,
  "wasSuccessful": true,
  "resultantTargetHash": "7237aec3...",
  "commonAncestor": "a5013d4f...",
  "targetBranch": "main"
}
```

```sql
trino> SELECT * FROM iceberg.demo.t ORDER BY id;
 id |      name
----+-----------------
  1 | hi
  2 | from-dev-branch
  3 | another
```

**5. Tag the current state as `v1`:**

```bash
MAIN_HASH=$(curl -s http://localhost:19120/api/v2/trees/main | jq -r .reference.hash)
curl -X POST "http://localhost:19120/api/v2/trees?name=v1&type=TAG" \
  -H "Content-Type: application/json" \
  -d "{\"type\":\"BRANCH\",\"name\":\"main\",\"hash\":\"$MAIN_HASH\"}"
```

**6. Commit history on `main`:**

```bash
curl -s http://localhost:19120/api/v2/trees/main/history | jq '.logEntries[] | .commitMeta | {hash, message, commitTime}'
```
```json
{ "hash": "7237aec3...", "message": "Iceberg append against demo.t", "commitTime": "2026-10-12T13:41:25Z" }
{ "hash": "a5013d4f...", "message": "Iceberg append against demo.t", "commitTime": "2026-10-12T13:38:34Z" }
{ "hash": "3d8145b0...", "message": "Iceberg append against demo.t", "commitTime": "2026-10-12T13:38:33Z" }
```

**7. Delete the `dev` branch:**

```bash
DEV_HASH=$(curl -s http://localhost:19120/api/v2/trees/dev | jq -r .reference.hash)
curl -X DELETE "http://localhost:19120/api/v2/trees/dev@$DEV_HASH"
```

### Time travel

Iceberg keeps a snapshot per write. Trino can read any past snapshot directly:

```sql
trino> SELECT snapshot_id, committed_at, operation
    -> FROM iceberg.demo."t$snapshots" ORDER BY committed_at;
     snapshot_id      |      committed_at       | operation
----------------------+-------------------------+-----------
  4496706724475371471 | 2026-10-12 13:38:33 UTC | append
  6497534049179426145 | 2026-10-12 13:38:34 UTC | append
  1440091372950113411 | 2026-10-12 13:41:25 UTC | append

trino> SELECT * FROM iceberg.demo.t FOR VERSION AS OF 6497534049179426145 ORDER BY id;
 id | name
----+------
  1 | hi
```

That's the table as it existed right after the first insert, independent of what has happened to `main` since. `FOR TIMESTAMP AS OF TIMESTAMP '…'` works too.

For **catalog-level** time travel (every table rewound to a past point in time), pin a new Trino catalog file at a specific Nessie hash: `iceberg.nessie-catalog.ref=<hash>`.

## Running the full demo

```bash
./demo-branching.sh
```

Walks through branch → divergence → merge → tag → history → time-travel → cleanup, with the actual command output. Takes about 10 seconds.

## Why these pieces

- **Iceberg** — open table format: ACID writes, hidden partitioning, time travel, schema evolution without rewriting data.
- **Nessie** — gives the catalog itself git semantics on top of Iceberg tables, so you get cross-table transactions, dev/prod data isolation, and auditable history.
- **RustFS** — Rust-based, MinIO-compatible S3 server. Lightweight, fast, drop-in for anywhere you'd use S3 locally.
- **Trino** — federated MPP engine that speaks Iceberg natively via the Nessie REST catalog.
- **Postgres** — Nessie's durable version store. In-memory and RocksDB backends also exist; JDBC/Postgres is the production-ready choice.

## Troubleshooting

- **`postgres` exits with "unused mount/volume"** — Postgres 18's image expects the volume at `/var/lib/postgresql` (not `/data`). This repo already does that; make sure you're not using a pre-existing volume from an older setup.
- **Merge/delete returns `"Expected hash must be provided."`** — Nessie v2 requires the current hash as a guard. Use `name@hash` in the URL path, not a query param.
- **`iceberg_dev` catalog missing after editing** — Trino only re-reads catalogs on restart: `docker compose restart trino`.
- **`s3://warehouse/...` writes fail** — confirm the bucket exists: `docker exec rustfs ls /data`.

## Project layout

```
.
├── docker-compose.yml
├── .env.example
├── trino/
│   └── catalog/
│       ├── iceberg.properties        # points at Nessie ref=main
│       └── iceberg_dev.properties    # points at Nessie ref=dev
├── demo-branching.sh                 # end-to-end git-features walkthrough
└── README.md
```

## License

MIT — do whatever you like with it.
