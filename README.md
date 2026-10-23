# CloudSaver on Azure Container Apps

Native Azure Container Apps deployment for CloudSaver **1.3.0** and its separate Platform **1.0.0** configuration contracts. This repository owns infrastructure, deployment scripts and tests. Application source stays in [ashokkondapuram/project](https://github.com/ashokkondapuram/project); Kubernetes charts stay in [cloudsaver-helm](https://github.com/ashokkondapuram/cloudsaver-helm).

The deployment targets an **existing Container Apps environment** by default. An optional environment template is included for a new VNet-integrated environment. No Azure resources are created by cloning this repository or by its push/PR validation workflow.

**Verified:** Bicep compilation/type checks and 33 offline configuration, deployment-control and compiled-template tests. **Outstanding:** live Azure deployment, database migrations, Entra sign-in, cloud scans and recovery acceptance. The current application snapshot has confirmed startup blockers; [application compatibility](docs/COMPATIBILITY.md) explains them. The scripts block migration/runtime apply with that known broken source revision.

## Deployment topology

| Container App | Ingress | Port | Replicas |
|---|---|---:|---|
| `<prefix>-dashboard` | External HTTPS | 3000 | 2–4 |
| `<prefix>-portal` | External HTTPS, optional CIDR allowlist | 3100 | 1 |
| `<prefix>-identity` | Environment internal | 8005 | 2–4 |
| `<prefix>-gateway` | Environment internal | 8000 | 2–4 |
| `<prefix>-tenant` | Environment internal | 8001 | 1 |
| `<prefix>-scanner` | Environment internal | 8002 | 1 |
| `<prefix>-analytics` | Environment internal | 8003 | 2–4 |
| `<prefix>-notifications` | Environment internal | 8004 | 2–4 |
| `<prefix>-worker`, `-scheduler`, `-dispatcher` | None; disabled by default | — | 1 when enabled |

Two **manual Container Apps Jobs**, `-migrate-platform` and `-migrate-cloud`, use separate owner credentials and identities. Deployment creates Jobs first; creating a Job does not execute it. Runtime apps are deployed only after both executions succeed and are checked again in Azure.

Services use actual ingress FQDNs returned by Azure over HTTPS, rather than Docker service names/ports. Only the two frontends expose external ingress. In an internal/ILB environment, “external” still means reachable through that environment's VNet/private entry path; it does not create a public route through an internal environment.

## 1. Prepare Azure and application images

Install Python 3.12, Azure CLI with its current `containerapp` extension, Bicep **0.48.1**, and the development Python dependencies:

```bash
python3 -m pip install -r requirements-dev.txt
az login
az extension add --name containerapp --upgrade
az bicep install --version v0.48.1
```

Prepare these resources in the **same Azure subscription**:

- Deployment resource group and an existing Container Apps environment. Configure environment/VNet routing, private DNS and access to data services before deployment. All app identities use the configured environment region.
- An Azure Container Registry with ARM-audience authentication enabled and standard registry RBAC. This release grants `AcrPull`; it rejects ABAC repository-permission registries instead of claiming that `AcrPull` works for them.
- An Azure Key Vault using Azure RBAC, reachable from the Container Apps environment and the deployment runner. Existing secrets are required before the Jobs stage.
- A stable user-assigned managed identity for cloud scanning. Example provisioning command: `az identity create --resource-group <rg> --name cloudsaver-scan`. Keep its identity across releases because customer federation/trust refers to it.
- Separate PostgreSQL 16 databases for CloudSaver and Platform, and separate private Redis endpoints for their broker/lease and identity-throttle data. Bring these services; no database or Redis container is created inside Container Apps.

Use unprivileged runtime database users `cloudsaver_app` and `identity_app`, separate schema-owner migration users, forced tenant RLS, verified PostgreSQL TLS (`sslmode=verify-full`) and Redis TLS (`rediss://`). Platform also needs the NOLOGIN `identity_retention` role. Provision roles/ownership and test migrations using the application's database init/migration instructions before relying on the Jobs. CloudSaver Redis must support logical databases 0 and 1 and durable broker/lease behavior; cluster-only DB-0 Redis products are incompatible without application changes. [Networking and identity](docs/IDENTITY_AND_NETWORKING.md) covers these boundaries.

Build and push four images from a **reviewed, corrected application revision**: `Dockerfile.services` at source root, `web-dashboard/Dockerfile`, `platform/Dockerfile`, and `platform/portal/Dockerfile`. Preserve each Dockerfile's intended build context. Record immutable ACR image digests in configuration; mutable tags are rejected. This repository does not build images from the known broken upstream snapshot or silently patch application code.

The deployment identity needs resource deployment rights in the target resource group, read access to the existing environment/registry/vault/cloud identity, Key Vault secret metadata listing, and role-assignment write rights at the registry and each selected vault-secret scope. It does not need to read secret **values** for these scripts. Review RBAC scopes before granting the deployment identity these privileges.

## 2. Configure Key Vault and Entra

Create a protected local configuration directory:

```bash
mkdir -m 700 config
cp examples/production.json config/production.json
chmod 600 config/production.json
```

Replace placeholder subscription/resource/region names, Entra IDs, image digests and secret names. The JSON file contains **references and non-secret settings only**. Do not add database URLs, tokens, keys or passwords. JSON-schema and invariant validation reject structural overrides and common inline credential fields.

Provision each secret listed under `secretNames`. The [secret contract](docs/SECRET_CONTRACT.md) lists required values and which app/job receives each. For operator-owned protected files, use `az keyvault secret set --vault-name <vault> --name <secret-name> --file config/<private-file> --output none`; keep such files untracked and 0600. An approved secret-manager pipeline is preferable. Never put actual secret values in shell arguments, ARM parameters, GitHub variables or logs.

Register workforce Entra API/portal applications, delegated API scope and the `PlatformOperator` / `PlatformAuditor` application roles. Assign operators explicitly and apply your MFA policy. Set the exact API access-token audience. Register the portal callback as `https://<portal-host>/api/auth/callback`. With no custom domain, its public host will be `<prefix>-portal.<environment-default-domain>`; query the environment's default domain before Entra registration. `portalPublicUrl` can specify a custom HTTPS origin when `portalDomain` supplies the matching hostname and an existing ACA environment certificate resource ID. The template manages that binding; provision/validate DNS and the certificate separately. For first deployment, use the generated hostname, complete custom-domain verification, then change the binding/configuration and re-establish migration evidence. These templates do not provision Entra registrations, DNS or custom-domain certificates.

After validating corrected application images and their migration/startup path in staging, record their source commit and acceptance evidence in `application.sourceRevision` and `application.acceptanceRecord`. The sample deliberately names the known blocked source and has no acceptance evidence. A different source hash is not itself evidence of successful testing.

## 3. Validate and plan

```bash
python3 scripts/deploy.py check --config config/production.json
python3 scripts/deploy.py plan --config config/production.json
```

`check` is offline and allows the published example so configuration structure can be tested. `plan` rejects placeholder values, reads Azure metadata, verifies region/profile/registry/vault references and runs ARM **what-if** for the runtime topology. It does not create resources or start Jobs. It lists change types/resource IDs without dumping full app configuration or secret values. What-if requires Azure access and is separate from offline Bicep compilation.

## 4. Deploy in order

Back up both databases, test restore, review migrations and establish the maintenance window for an existing installation. Pause scheduler/disabled worker revisions and stop application writes where migrations require it; see [operations](docs/OPERATIONS.md).

```bash
# Create managed identities, scoped RBAC and manual migration Job definitions.
python3 scripts/deploy.py jobs --config config/production.json --apply

# Start Platform migration, wait for Succeeded, then start CloudSaver migration.
python3 scripts/deploy.py migrate --config config/production.json --apply

# Recheck the receipt and Azure execution states, then deploy runtime apps.
python3 scripts/deploy.py runtime --config config/production.json --apply

python3 scripts/deploy.py status --config config/production.json
```

Every mutating phase requires `--apply`. CLI calls always select the configuration's subscription explicitly. RBAC propagation, private DNS and registry/Key Vault firewall access may need time before ACA can resolve image/secret references. Fix those prerequisites and rerun the appropriate phase deliberately; the scripts do not repeatedly submit failed or uncertain Jobs.

Migration Jobs allow one replica and zero automatic retries. Before starting, the script checks that the deployed Job matches this exact config/infra fingerprint and image digest, and that no execution is running/uncertain. It only writes `.state/` evidence after both executions succeed. Runtime checks that receipt against the same configuration/templates and re-reads each execution's successful state in Azure. Changing config/templates requires updating the Jobs and migrating again. Retention/deletion of old executions can invalidate receipts; inspect history and deliberately establish new evidence. The local receipt is not an exactly-once or distributed-lock guarantee: serialize all deployment operators.

The optional [manual GitHub workflow](.github/workflows/deploy.yaml) runs all three mutation phases in one runner so the receipt stays available. Configure the GitHub `production` environment with non-secret variables `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, and `ACA_CONFIG_JSON`. Configure an Entra federated credential for `repo:ashokkondapuram/cloudsaver-containerapps:environment:production` and the deployment identity's reviewed Azure roles. It uses OIDC and defaults to **plan**; choose **deploy** deliberately after source/application acceptance. Push/PR validation has no Azure login or deployment permissions. [CI details](docs/OPERATIONS.md) describe limitations.

## Optional environment creation

If you need a new Container Apps environment, first prepare a correctly sized/delegated dedicated infrastructure subnet and required DNS/routing. Review the environment template and run a separate deployment:

```bash
az deployment group what-if --resource-group <environment-rg> \
  --template-file infra/environment.bicep \
  --parameters environmentName=<name> location=<region> infrastructureSubnetId=<subnet-resource-id>

az deployment group create --resource-group <environment-rg> \
  --template-file infra/environment.bicep \
  --parameters environmentName=<name> location=<region> infrastructureSubnetId=<subnet-resource-id>
```

This creates a Log Analytics workspace and a VNet-integrated environment with a Consumption workload profile. `internalEnvironment=true` is the default; set false only if you intend an externally reachable environment. It does not create the subnet, private DNS, ACR, Key Vault, data services or scanning identity. It does not modify an existing environment. Zones are not enabled by this minimal optional template; configure an environment designed for your availability/region requirements before deploying production workloads.

## Optional features and verification

All scans-on-schedule, automated alerts, interactive jobs, delivery, AI and GitOps publishing flags default off. Enable corresponding worker components and configure tenant-bound targets, cloud/model IAM and plan entitlements first. Scheduled scans require all three workers; interactive jobs require worker+dispatcher; delivery requires dispatcher; automated alerts require delivery. AI batches need worker+scheduler in addition to model targets. Deployment feature flags do not overwrite existing persisted Platform settings; configure those through the Platform.

Run probes, Entra sign-in, two-workspace isolation, key revocation, directory projection, saved-history restart checks, read-only cloud access and backup/restore acceptance in your environment. Platform billing remains disabled pending the source compatibility work. Runtime instances use image-defined non-root users; the repository does not claim Kubernetes-only securityContext/NetworkPolicy settings apply to ACA.

For offline development validation:

```bash
python3 -m pip install -r requirements-dev.txt
make check test BICEP=/path/to/bicep
```

Bicep builds into ignored `dist/`. The 33 tests cover topology, permissions, secret separation, deployment controls and failure cases with mocked Azure CLI calls. No live cloud scan, inference, remediation, billing action, migration or deployment is performed by those tests. See [verification](docs/VERIFICATION.md).
