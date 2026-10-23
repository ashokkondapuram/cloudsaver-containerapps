# Identity and networking

## Managed identities

A stable, pre-existing **scanning user-assigned managed identity** is attached only to scanner and scan-worker. `AZURE_CLIENT_ID` selects it, while Container Apps supplies its managed identity endpoint/header. This matches the application's ManagedIdentityCredential implementation. The templates do not inject endpoint headers, mount developer Azure CLI caches, or create customer Reader grants.

Each workload additionally gets its own configuration identity. It can pull its configured ACR images and read only its assigned Key Vault secret resources. Migration identities receive only their owner-DSN secret and registry pull role; they never receive the scanning identity. These identities are different from the **GitHub OIDC deployment identity**.

Configure customer access/federation per upstream `docs/MANAGED_IDENTITY_ROLES.md`: Azure multi-tenant application federated credentials + customer subscription read grants, AWS hub/customer roles with tenant external IDs, and GCP workload-identity federation/tenant service accounts. Set the Azure application client ID and other non-secret provider bindings in `backendConfig`. Do not grant broad write permissions to the scanning identity.

## Routing and isolation

All apps/Jobs run in one selected ACA environment. Only dashboard and portal have `external: true`; all API ingress is environment-internal. Backend URLs use actual resource ingress FQDN outputs over HTTPS. The optional environment template defaults to an internal VNet environment, requiring private DNS and a deliberate operator/customer access path. “External ingress” on an internal environment does not expose it directly to the Internet.

Internal ACA ingress is reachable by other workloads in that environment. ACA does not enforce the Helm repository's Kubernetes namespace/pod NetworkPolicies. Treat the environment as a shared network trust boundary: do not host untrusted applications there, retain API bearer/service-token checks, isolate data services with private endpoints/firewalls/least-privilege logins and plan further separation if required. This release does not claim mutually authenticated per-app network isolation.

Configure DNS/routes/NSGs/egress for ACR image pulls, Key Vault, PostgreSQL, Redis, Microsoft Entra signing/token endpoints, required Azure control/data APIs, and only the explicitly enabled AWS/GCP/model/webhook targets. API egress/identity federation needs live acceptance. A private Key Vault requires both runtime and deployment-runner reachability. The GitHub hosted deployment workflow cannot reach your private VNet merely because it can authenticate; use a runner with approved network access when required.

Registry authentication uses managed identity and AcrPull. Enable ACR ARM-audience authentication. ABAC repository-permission mode requires a different reviewed binding and is deliberately rejected by preflight. RBAC propagation may delay the first image pull/Key Vault reference resolution. There are no registry passwords in templates.

## Client IP and auth

The application currently resolves trusted proxies using peer IP/CIDR checks designed for direct service networking. ACA ingress inserts proxy hops; resolving an app FQDN does not identify its original caller pod. Therefore `CLOUDSAVER_TRUSTED_CALLERS` defaults empty here, and `trustedProxyCidrs` defaults empty. No forwarding source is trusted implicitly. Configure a verified header/proxy policy and test the complete ACA ingress chain before relying on source IP attribution or per-IP login throttling across customers. Token/tenant authentication remains required; source-IP logging is not an identity boundary. `0.0.0.0/0` and `::/0` are rejected as trusted proxy ranges.

Operator portal uses explicit workforce Entra tenant/audience and application roles. Custom-domain certificates/bindings, registrations, role assignments, delegated scope consent, MFA and browser acceptance remain operator tasks. Platform customer consent/onboarding and other unfinished source features are not supplied by infrastructure.
