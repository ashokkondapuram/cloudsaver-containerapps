# Application compatibility and deployment gates

This infrastructure targets the documented configuration of application commit `6fc05bb3215a300bbec3b05218614dce35a4403d` in `ashokkondapuram/project`. It targets CloudSaver 1.3.0 / Platform 1.0.0 configuration contracts. No application code or credentials are copied into this repository.

Bicep compilation and offline tests validate infrastructure structure/configuration contracts. They do not prove that the source application's current images start successfully.

The upstream snapshot has confirmed Platform blockers:

- `identity/app.py` imports `app.runtime`, but the isolated Platform Dockerfile does not include CloudSaver's `app` package.
- Platform runtime/migration code still reads legacy `CLOUDSAVER_IDENTITY_DATABASE_URL` / `CLOUDSAVER_IDENTITY_MIGRATION_URL` in places, while its separate Compose stack supplies the new `PLATFORM_*` settings. The deployment deliberately supplies the intended new names.
- IdentityService still reads legacy environment/provider-scope settings; without correcting it, the new production setting does not control production key prefixes as intended.
- A source compatibility test exposed `ImportError: cannot import name 'TIERS' from 'identity.domain'`. The service still expects a three-argument `normalize_scope_items` interface, while the updated domain defines a four-argument interface. Billing/store changes and migration completeness must be reviewed together; replacing one missing constant is not a sufficient fix.
- The separate Compose stack omits the workforce operator tenant ID from identity-service's environment. The Container Apps template explicitly supplies `PLATFORM_OPERATOR_TENANT_ID`.

This repository contains no application patches or migration rewrites. Build images from a reviewed, corrected source revision and record their immutable digests in production configuration. Application fixes and live acceptance must be completed in the application release process.

Before production installation, validate the complete isolated Platform image (no source bind mounts), migration paths on disposable PostgreSQL, Entra token audience/roles, directory projection and key lifecycle. Current application docs also reference billing migration/import components that are absent in this snapshot: keep billing disabled until that path is complete and tested.

On Container Apps, the selected scanning managed identity is attached directly and its client ID is supplied to ManagedIdentityCredential. This avoids the AKS WorkloadIdentityCredential mismatch, but still requires actual endpoint, federation, customer RBAC and cloud acceptance. Infrastructure does not repair the source issues above.

None of these issues is concealed by Container Apps readiness probes or by successful Bicep compilation. The templates are ready for review and integration testing; production application acceptance is outstanding.

The deployment scripts reject migration/runtime apply for the confirmed broken source revision or an empty application acceptance record. Fix/review the application, publish digest-pinned images, and record the tested source revision and evidence. Changing the record alone does not fix the application. No application patch is imported into this repository.
