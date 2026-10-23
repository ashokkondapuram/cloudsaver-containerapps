# Deployment operations

## Migrations and existing installations

The supported entrypoint is `scripts/deploy.py`, which validates configuration and uses explicit subscription selection. Running Bicep directly bypasses script guards; do not use raw template deployments as a way to skip source acceptance, migration receipts or worker checks.

Before upgrading, record immutable source/image references, back up both databases, test restore on isolated data and review both migration lineages. Keep schema owners separate from runtime roles. Stop application writes where a migration needs it. This repository does not automatically drain traffic, stop all API writes, back up databases, or prove an upgrade is backward-compatible.

`jobs --apply` creates identities, scoped RBAC and manual migration Job definitions without starting executions. It does not update existing runtime apps. ARM uses incremental mode: omitted conditional apps are **not deleted or stopped**. Changing `workers.*` to false alone cannot disable an existing worker. The script detects active disabled-worker/scheduler revisions and stops with instructions instead of leaving them silently running.

For scheduler upgrades or disabling an existing worker, deliberately pause it before any mutating stage. Container Apps revision mode can be changed to Multiple to deactivate active revisions while preserving their definitions. Example for one app, after reviewing queued/in-flight work:

```bash
az containerapp revision set-mode --name <prefix>-scheduler --resource-group <rg> --mode Multiple
az containerapp revision list --name <prefix>-scheduler --resource-group <rg> \
  --query "[?properties.active].name" --output tsv
az containerapp revision deactivate --name <prefix>-scheduler --resource-group <rg> --revision <active-revision-name>
```

Include `--subscription <id>` when working outside your selected CLI context. Repeat deliberately for workers you are disabling. The script verifies there are no active scheduler revisions before applying an upgrade. New enabled workers are created during runtime; disabled existing app definitions stay paused for recovery. Inspect and deliberately reactivate the prior revision if you abort deployment. Do not reactivate old Beat alongside a new scheduler.

ACA min/max replica settings apply per revision and do not provide a distributed singleton lease. Single revision mode can overlap old/new revisions briefly during updates. The portal is one replica with sticky affinity but its sessions/OAuth state remain process-local: upgrades/restarts interrupt sign-in and lose sessions. Beat updates require the pause above; application schedule reservations are not a replacement for reviewed scheduler operations. Queued scan work also needs an explicit drain/recovery policy before incompatible updates.

Migration Jobs run Platform first, then CloudSaver, with one replica, a 900-second deadline and zero automatic retries. A detected running/unknown execution blocks duplicate starts. Network loss, timeout or start ambiguity never creates a successful receipt. Inspect the existing Job execution in Azure before retrying:

```bash
az containerapp job execution list --name <prefix>-migrate-platform --resource-group <rg> \
  --query "[].{name:name,status:properties.status}" --output table
```

The script is not a global transaction/distributed migration lock. Serialize every deployment operator/runner, including actions outside this repository. If a failed stage leaves an uncertain execution, resolve its actual outcome before a new deployment. An operator changing databases directly can invalidate evidence beyond what a config fingerprint detects.

## Recovery

Local `.state/` receipt files have mode 0600 and are not committed. Runtime validates their configuration/infra fingerprint and asks Azure to confirm the referenced executions still succeeded. Replacing/loss of local state, pruning execution history or changing configuration requires deliberate re-establishment of migration evidence. Do not fabricate a receipt or claim a successful execution from a deployment Job definition alone.

Rolling back an ACA revision does not reverse SQL schema changes. Keep reviewed image/schema compatibility and tested backup/restore procedures. The repository does not run destructive cleanup or delete data services. Incremental template updates do not revoke obsolete RBAC assignments or remove disabled apps; audit old grants/revisions and remove them only after a reviewed rollback window.

Key Vault references are versionless. Coordinate secret rotation and ACA revision/restart behavior with current Container Apps secret refresh semantics; explicitly verify each app resolves the intended version. Owner and runtime DSNs never share one Key Vault name. Preserve the workspace pepper/version and previous-key compatibility. An operator must revoke superseded grants/tokens deliberately; changing a parameter is not proof that the previous credential stopped working.

## Probes, scaling and cost

API startup/liveness use `/healthz`; readiness uses `/readyz`. Dashboard uses `/`; portal uses `/api/healthz`. Frontend probes do not establish end-to-end API/Entra readiness. Workers have no fake HTTP probes and keep min/max 1 while enabled. Process exit restarts them. Worker termination grace is 600 seconds; stop/drain long tasks before deployment and verify broker redelivery/fencing during acceptance.

Each app uses 0.5 vCPU/1 GiB; defaults keep API/UI replicas warm rather than scaling to zero. Gateway, identity, analytics, notifications and dashboard can scale 2–4 with an HTTP request rule; tenant projector, scanner, portal and workers stay at 1. Database pool size is per process: budget connections across every replica and worker child. This is a starting resource allocation, not a load/SLA guarantee. Monitor latency, DB/Redis saturation, replica count, Log Analytics ingestion and spend before increasing limits.

## GitHub workflow

`validate.yaml` runs on pushes/PRs with contents-read permission only and no Azure credentials. It installs checksum-pinned Bicep, compiles both templates and runs offline tests.

`deploy.yaml` is manual, bound to the `production` environment and defaults to `plan`. Configure OIDC federation and reviewed roles, four non-secret variables and a network-capable runner. Store only non-secret config JSON in `ACA_CONFIG_JSON`; secrets stay in Key Vault. The subscription in JSON must match `AZURE_SUBSCRIPTION_ID`. Deployment mode runs Jobs, migrations and runtime in one runner. Its concurrency group queues deployments rather than canceling a running migration. This does not coordinate operators outside GitHub.

No workflow was dispatched to Azure as part of repository preparation. Actual Azure what-if/provider validation, migration/startup acceptance, role propagation, environment DNS, Entra sign-in, tenant isolation, live cloud scans and restore remain required before production service.
