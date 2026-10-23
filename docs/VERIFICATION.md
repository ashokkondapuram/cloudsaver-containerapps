# Verification record

Verified on 2026-10-23 against deployment repository version 0.1.0.

- Bicep **0.48.1.52935** (GitHub release v0.48.1), verified by SHA256 before execution.
- `infra/main.bicep` and `infra/environment.bicep` compile successfully with Azure resource type checking and the repository's analyzer settings. No compiler errors or warnings were emitted by the final build.
- **33 tests pass**, using an isolated Python environment with the pinned `jsonschema==4.25.1` dependency. Tests include configuration rejection/secret isolation, source acceptance gates, private parameter files, explicit subscription selection, metadata-only preflight, worker transition checks, uncertain/failed migration outcomes, execution ordering, image/config fences, receipt revalidation, custom-domain configuration and the compiled ARM topology/RBAC structure.
- The example configuration passes offline contract checks; its placeholders and confirmed broken source revision deliberately prevent live apply.
- Both GitHub workflow YAML files parse. Validation is push/PR-only and has no Azure login. Deployment is workflow-dispatch-only, defaults to plan, and uses OIDC rather than stored Azure credentials.

Commands executed:

```bash
make build BICEP=/path/to/bicep
python3 -m unittest discover -s tests -v
python3 scripts/deploy.py check --config examples/production.json
```

All Azure CLI calls in the deployment tests are mocked. No Azure what-if/provider validation, resource creation, migration Job execution, live Entra sign-in, cloud scan/inference, notification, billing or remediation was performed. No application image was built. Corrected source/application acceptance, Azure identity/role propagation, registry/Key Vault/private-network access, workload startup, tenant isolation and backup/restore checks remain deployment prerequisites. Bicep compilation is not Azure runtime certification.
