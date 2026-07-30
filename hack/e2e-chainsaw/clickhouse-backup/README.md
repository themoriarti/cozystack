# ClickHouse Altinity backup E2E

Chainsaw suite for the ClickHouse Altinity backup/restore flow (`strategy.backups.cozystack.io/v1alpha1` `Altinity` + `backups.cozystack.io/v1alpha1` `BackupJob`/`RestoreJob`). It replaces the never-merged `hack/e2e-apps/backup-clickhouse.bats` from cozystack#2600 with the current Chainsaw approach, and is split into two Tests run in name order — the same shape as the `etcd` suite.

## `clickhouse-backup-1-contracts` (runs in CI)

Deploys a single-shard, single-replica ClickHouse with `backup.enabled: true` and asserts the contract the Altinity strategy depends on, against the running cluster rather than the chart templates:

- the HelmRelease and StatefulSet become Ready;
- the ClickHouseInstallation Pod carries the `clickhouse-backup` sidecar exposing the container port named `ch-backup-api` (`:7171`), the HTTP API the strategy Pod drives;
- the chart-emitted `clickhouse-test-backup-backup-api-auth` Secret exists and is populated (the credentials both the sidecar and the strategy Pod read).

Placeholder S3 coordinates are intentional: `clickhouse-backup server` starts its API without validating S3, so this Test needs no reachable object store. If a chart bump renames the sidecar container, moves the port, or renames the auth Secret, every ClickHouse `BackupJob` breaks silently — this Test catches it on every PR.

## `clickhouse-backup-2-roundtrip` (runs in CI)

The full round-trip: `Bucket` → `Altinity` strategy + `BackupClass` → backup-enabled source ClickHouse (with a sentinel write) → `BackupJob` (waits `Succeeded`, emits a `Backup`) → in-place `RestoreJob` → to-copy `RestoreJob` into a second ClickHouse. It drives `examples/backups/clickhouse/run-all.sh` as the harness, so the test and the documented flow cannot drift. This is the Test that proves backup and restore actually work; the contracts Test above only proves the chart still exposes the surface they need.

It runs in **`tenant-root`**, not the default `tenant-test`, and mirrors `mariadb-2-backup-roundtrip` / `postgres-2-backup-roundtrip`. Three things make it possible:

- the S3 client is the `clickhouse-backup` sidecar *inside* the tenant, and the e2e tenant is created isolated — its Cilium egress allowlist blocks a `tenant-test` Pod from reaching `tenant-root`'s SeaweedFS, while a `tenant-root` Pod reaches it over same-tenant egress;
- the harness targets the in-cluster endpoint `https://seaweedfs-s3.tenant-root:8333` rather than the `Bucket`'s external ingress URL, which in CI is the unroutable `s3.example.org` placeholder;
- that endpoint's self-signed certificate is trusted by copying the SeaweedFS CA (`seaweedfs-ca-cert`, auto-discovered from its cert-manager `Certificate`) into a per-release Secret referenced by the chart's `backup.endpointCA`, which mounts it into the sidecar and points `SSL_CERT_DIR` at it.

The last point is the one that used to be missing: before `backup.endpointCA` existed the sidecar had no CA surface at all, so the round-trip could not verify TLS against the in-cluster endpoint and was skipped behind an env gate. `SSL_CERT_DIR` is used rather than `AWS_CA_BUNDLE` because Go reads it *in addition to* the system trust store, so a release with a private CA still reaches publicly-trusted endpoints.

## Running

Both Tests run as part of the normal suite:

```sh
chainsaw test hack/e2e-chainsaw/clickhouse-backup
```

The contracts Test uses the `tenant-test` namespace configured in `hack/e2e-chainsaw/.chainsaw.yaml`; the round-trip overrides it to `tenant-root` for the reason above.

## Cleanup

The contracts Test lets Chainsaw delete the ClickHouse it applied. The round-trip Test creates its resources through the example scripts (not Chainsaw `apply`) and also produces controller-owned artifacts — the `Backup` CR, the copied CA Secret and the cluster-scoped `Altinity` strategy + `BackupClass` — so it tears them down itself in a `finally` running `examples/backups/clickhouse/cleanup.sh`. The same script also runs *before* the flow: `tenant-root` is shared and persistent with fixed resource names, so a run killed before the `finally` would otherwise leave a `Succeeded` `BackupJob` behind that satisfies the harness's wait instantly and passes without a real backup. `cleanup.sh` is idempotent (`--ignore-not-found`), so the pre-clean is a no-op on a clean namespace, and it never touches the platform's own SeaweedFS CA Secret — only the per-release copy.
