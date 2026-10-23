# Changelog

## 0.1.0

- Add native Bicep deployment into an existing Azure Container Apps environment and an optional VNet environment template.
- Separate internal APIs, external web apps, opt-in workers and manual migration Jobs.
- Use per-workload identities and secret-scoped Key Vault access; attach stable scanning identity only to scanner/worker.
- Add image pinning, configuration validation, staged Jobs/migrations/runtime execution and Azure execution receipt checks.
- Add Entra, data-service, private networking, custom-domain, worker upgrade and recovery instructions.
- Add 33 offline tests and separate validation/manual OIDC deployment workflows.
- Document and gate known upstream application startup incompatibilities; no live Azure rollout is claimed.
