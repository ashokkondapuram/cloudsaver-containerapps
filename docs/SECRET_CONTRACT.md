# Key Vault secret contract

The values below live in existing Azure Key Vault secrets. Configuration stores only their **names**. Secrets use versionless Key Vault references; record/coordinate rotations with ACA revisions and application credential grace periods. The scripts list secret metadata and never request values.

| `secretNames` key | Value contract | Consumers |
|---|---|---|
| `cloudDatabaseUrl` | PostgreSQL libpq DSN for restricted `cloudsaver_app`, verified TLS | CloudSaver Python apps/workers |
| `cloudRedisGatewayUrl` | TLS Redis URL for logical DB 0 | Gateway |
| `cloudRedisWorkerUrl` | TLS Redis URL for logical DB 1 | Other CloudSaver Python apps/workers |
| `gatewayCallerToken` | Independent random caller token | Gateway |
| `tenantCallerToken` | Independent random caller token | Tenant-service projector |
| `scannerCallerToken` | Independent random caller token | Scanner API |
| `analyticsCallerToken` | Independent random caller token | Analytics API |
| `notificationCallerToken` | Independent random caller token | Notifications API |
| `identityDatabaseUrl` | PostgreSQL DSN for restricted `identity_app`, verified TLS | Identity API |
| `identityRedisUrl` | Separate TLS Redis endpoint/logical DB | Identity API |
| `workspaceKeyPepper` | At least 32 random bytes encoded as hex; preserve across releases | Identity API |
| `identityCallerDigests` | JSON `{gateway,tenant,scanner,analytics,notification,portal}` mapping caller names to SHA256 hex digests of matching plaintext tokens | Identity API |
| `portalCallerToken` | Independent random token whose digest is in `identityCallerDigests` | Operator portal |
| `portalEntraClientSecret` | Confidential portal client's Entra secret | Operator portal |
| `cloudMigrationUrl` | CloudSaver schema-owner PostgreSQL DSN | CloudSaver migration Job only |
| `identityMigrationUrl` | Platform `identity_owner` PostgreSQL DSN | Platform migration Job only |

URL-encode DSN passwords. External database CA roots must be trusted by the **images**, including migration images. Configure required CA paths/driver settings in reviewed application images; these templates do not disable certificate verification or mount arbitrary private credential files. Ensure Redis certificates/hostnames are verified by the current clients.

Each app/Job has a distinct configuration managed identity with `AcrPull` and `Key Vault Secrets User` scoped to its explicitly named **secret resources**. Owner DSNs are absent from every runtime permission set. The dashboard has no core secret grants. Frontends receive only their own necessary settings/secrets. Creating RBAC does not revoke historical assignments; remove superseded role grants explicitly after a reviewed rotation.

`extraSecrets` supports additional per-workload integration bindings:

```json
{
  "workload": "scanner",
  "appSecretName": "gitops-key",
  "keyVaultSecretName": "cloudsaver-github-app-private-key",
  "envName": "CLOUDSAVER_GITHUB_APP_PRIVATE_KEY"
}
```

The workload-specific identity gets access only to that added secret. Validation rejects duplicate bindings and overriding core credentials/structural variables. Bind webhook secrets separately to the dispatcher/worker when they need them. Never use extra bindings to share migration credentials or workspace peppers with application workers.

Set `keyPepperVersion` to the version of the current material, especially when moving an existing installation. If the application needs previous peppers, bind `PLATFORM_KEY_PEPPER_PREVIOUS` through an additional identity-workload Key Vault secret using its supported `version:hex` comma-separated contract. Preserve current and previous material during a reviewed rotation. The templates do not generate or rotate peppers, rehash existing keys, or prove a rotation succeeded. Caller-token rotation must likewise keep matching identity digests and each caller's plaintext token in sync.
