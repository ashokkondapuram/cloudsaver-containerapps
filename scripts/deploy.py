"""Stage Azure Container Apps deployment. No mutations without --apply.

Commands: check (offline), plan (Azure what-if), jobs, migrate, runtime, status.
Secrets remain in Key Vault; CLI responses are reduced to metadata only.
"""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from configuration import (ROOT, ConfigError, fingerprint, load, parameters,
                           require_application_acceptance, require_real_values)

API_VERSION = '2025-01-01'
WORKERS = {'scan': 'worker', 'scheduler': 'scheduler', 'dispatcher': 'dispatcher'}


class DeploymentError(RuntimeError):
    pass


class Azure:
    def __init__(self, config, runner=subprocess.run):
        self.config, self.runner = config, runner

    def call(self, *args, missing_ok=False):
        command = ['az', *args, '--subscription', self.config['subscriptionId'], '--only-show-errors', '--output', 'json']
        result = self.runner(command, capture_output=True, text=True)
        if result.returncode:
            if missing_ok and ('ResourceNotFound' in result.stderr or 'ResourceGroupNotFound' in result.stderr):
                return None
            # Do not echo returned payloads/diagnostics that may contain runtime environment values.
            raise DeploymentError(f'Azure CLI failed: {" ".join(args[:3])}. Inspect the operation in Azure; no automatic retry was made.')
        try:
            return json.loads(result.stdout) if result.stdout.strip() else None
        except json.JSONDecodeError:
            raise DeploymentError('Azure CLI returned invalid JSON') from None


def preflight(config, azure):
    environment = azure.call('containerapp', 'env', 'show', '--name', config['environmentName'],
                             '--resource-group', config['environmentResourceGroup'],
                             '--query', '{location:location,id:id,profiles:properties.workloadProfiles}')
    if environment['location'].lower().replace(' ', '') != config['location'].lower():
        raise DeploymentError('Container Apps environment region does not match configuration')
    if config['workloadProfileName'] and config['workloadProfileName'] not in {
            p['name'] for p in (environment.get('profiles') or [])}:
        raise DeploymentError('The selected workload profile does not exist in the environment')
    registry = azure.call('acr', 'show', '--name', config['registryName'], '--resource-group', config['registryResourceGroup'],
                          '--query', '{server:loginServer,mode:roleAssignmentMode}')
    if registry.get('mode') == 'AbacRepositoryPermissions':
        raise DeploymentError('This template uses AcrPull; ABAC-enabled registries need a reviewed repository-reader binding')
    if any(image.split('/')[0] != registry['server'] for image in config['images'].values()):
        raise DeploymentError('Every image must come from the configured registry')
    vault = azure.call('keyvault', 'show', '--name', config['vaultName'], '--resource-group', config['vaultResourceGroup'],
                       '--query', '{rbac:properties.enableRbacAuthorization}')
    if vault.get('rbac') is not True:
        raise DeploymentError('The Key Vault must use Azure RBAC authorization')
    present = set(azure.call('keyvault', 'secret', 'list', '--vault-name', config['vaultName'], '--query', '[].name'))
    expected = set(config['secretNames'].values()) | {b['keyVaultSecretName'] for b in config['extraSecrets']}
    if not expected <= present:
        raise DeploymentError('Required Key Vault secret metadata is missing; provision every configured secret first')
    azure.call('identity', 'show', '--name', config['cloudIdentityName'],
               '--resource-group', config['cloudIdentityResourceGroup'], '--query', '{id:id,clientId:clientId}')
    # Read only metadata; do not fetch Secret values or full Container App environment definitions.


def assert_worker_transition(config, azure):
    """Incremental ARM deployments do not remove disabled workers. Never silently leave one running."""
    for key, suffix in WORKERS.items():
        name = config['prefix'] + '-' + suffix
        app = azure.call('containerapp', 'show', '--name', name, '--resource-group', config['resourceGroup'],
                         '--query', '{name:name}', missing_ok=True)
        if app is None:
            continue
        revisions = azure.call('containerapp', 'revision', 'list', '--name', name,
                               '--resource-group', config['resourceGroup'], '--query', '[?properties.active].name')
        if revisions and (key == 'scheduler' or not config['workers'][key]):
            raise DeploymentError('Pause existing scheduler/disabled worker revisions before deployment; see docs/OPERATIONS.md')


def deploy_template(config, azure, *, runtime, what_if=False):
    with tempfile.TemporaryDirectory(prefix='cloudsaver-aca-') as temp:
        path = Path(temp) / 'parameters.json'
        path.write_text(json.dumps(parameters(config, runtime)))
        path.chmod(0o600)
        operation = 'what-if' if what_if else 'create'
        args = ['deployment', 'group', operation, '--resource-group', config['resourceGroup'],
                '--name', config['prefix'] + ('-runtime' if runtime else '-jobs'),
                '--template-file', str(ROOT / 'infra/main.bicep'), '--parameters', '@' + str(path)]
        if what_if:
            # Resource IDs/change types only; never dump the complete what-if payload.
            args += ['--query', 'changes[].{changeType:changeType,resourceId:resourceId}']
        else:
            args += ['--query', '{state:properties.provisioningState,outputs:properties.outputs}']
        result = azure.call(*args)
        if not what_if and result.get('state') != 'Succeeded':
            raise DeploymentError('ARM deployment did not report Succeeded')
        return result


def wait_execution(azure, job, execution, *, timeout=960, clock=time.monotonic, pause=time.sleep):
    deadline = clock() + timeout
    while True:
        status = azure.call('containerapp', 'job', 'execution', 'show', '--name', job,
                            '--resource-group', azure.config['resourceGroup'], '--job-execution-name', execution,
                            '--query', 'properties.status')
        if status == 'Succeeded':
            return
        if status in ('Failed', 'Stopped', 'Canceled', 'Cancelled', 'Degraded'):
            raise DeploymentError('Migration execution did not succeed. Inspect it before retrying; runtime remains blocked.')
        if clock() >= deadline:
            raise DeploymentError('Migration outcome is uncertain after timeout. Inspect the existing execution; do not start a duplicate.')
        pause(5)


def migrate(config, azure, *, waiter=wait_execution):
    completed = []
    for suffix, image in [('platform', config['images']['identity']), ('cloud', config['images']['python'])]:
        job = config['prefix'] + '-migrate-' + suffix
        metadata = azure.call('containerapp', 'job', 'show', '--name', job, '--resource-group', config['resourceGroup'],
                              '--query', '{image:properties.template.containers[0].image,fingerprint:tags.deploymentFingerprint}')
        if metadata != {'image': image, 'fingerprint': fingerprint(config)}:
            raise DeploymentError('Migration job image/configuration differs; deploy the jobs stage again')
        executions = azure.call('containerapp', 'job', 'execution', 'list', '--name', job,
                                '--resource-group', config['resourceGroup'], '--query', '[].{name:name,status:properties.status}')
        if any(item.get('status') not in ('Succeeded', 'Failed', 'Stopped', 'Canceled', 'Cancelled') for item in executions):
            raise DeploymentError('A migration execution is running or uncertain; inspect it instead of starting a duplicate')
        execution = azure.call('containerapp', 'job', 'start', '--name', job, '--resource-group', config['resourceGroup'], '--query', 'name')
        if not execution:
            raise DeploymentError('Migration start outcome is uncertain; inspect executions before retrying')
        waiter(azure, job, execution)
        completed.append({'job': job, 'execution': execution, 'status': 'Succeeded'})
    return {'fingerprint': fingerprint(config), 'completedAt': datetime.now(timezone.utc).isoformat(), 'jobs': completed}


def receipt_path(config):
    return ROOT / '.state' / (config['subscriptionId'] + '-' + config['resourceGroup'] + '-' + config['prefix'] + '.json')


def write_receipt(config, receipt):
    path = receipt_path(config)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temp = path.with_suffix('.tmp')
    descriptor = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        json.dump(receipt, stream)
    os.replace(temp, path)


def verify_receipt(config, azure, path=None):
    path = path or receipt_path(config)
    if not path.exists():
        raise DeploymentError('No successful migration receipt exists; run migrate after the jobs stage')
    receipt = json.loads(path.read_text())
    expected_jobs = {config['prefix'] + '-migrate-platform', config['prefix'] + '-migrate-cloud'}
    if receipt.get('fingerprint') != fingerprint(config) or {j.get('job') for j in receipt.get('jobs', [])} != expected_jobs or len(receipt.get('jobs', [])) != 2:
        raise DeploymentError('Migration receipt does not match this exact config/template; run jobs and migrate again')
    # Local files alone are not evidence: recheck each referenced execution in Azure.
    for job in receipt['jobs']:
        status = azure.call('containerapp', 'job', 'execution', 'show', '--name', job['job'],
                            '--resource-group', config['resourceGroup'], '--job-execution-name', job['execution'],
                            '--query', 'properties.status')
        if status != 'Succeeded' or job.get('status') != 'Succeeded':
            raise DeploymentError('A referenced migration execution is not successful')
    return receipt


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['check', 'plan', 'jobs', 'migrate', 'runtime', 'status'])
    parser.add_argument('--config', required=True)
    parser.add_argument('--apply', action='store_true', help='Required for jobs, migrate and runtime mutations')
    args = parser.parse_args(argv)
    config = load(args.config)
    if args.phase == 'check':
        print('Configuration contract valid. Placeholder detection, Azure preflight and live acceptance are separate.')
        return 0
    if args.phase in ('jobs', 'migrate', 'runtime') and not args.apply:
        raise DeploymentError('This phase mutates Azure; use --apply explicitly or choose plan for read-only what-if')
    require_real_values(config)
    if args.phase in ('migrate', 'runtime'):
        require_application_acceptance(config)
    azure = Azure(config)
    if args.phase == 'status':
        result = azure.call('containerapp', 'list', '--resource-group', config['resourceGroup'],
                            '--query', "[?tags.managedBy=='cloudsaver-containerapps'].{name:name,state:properties.provisioningState,fqdn:properties.configuration.ingress.fqdn}")
        print(json.dumps(result, indent=2))
        return 0
    preflight(config, azure)
    if args.phase == 'plan':
        print(json.dumps(deploy_template(config, azure, runtime=True, what_if=True), indent=2))
    elif args.phase == 'jobs':
        assert_worker_transition(config, azure)
        deploy_template(config, azure, runtime=False)
        print('Migration jobs deployed. No migration was started and no runtime app was created by this phase.')
    elif args.phase == 'migrate':
        assert_worker_transition(config, azure)
        # Remove stale evidence before starting; a failed/uncertain run cannot reuse an older receipt.
        receipt_path(config).unlink(missing_ok=True)
        write_receipt(config, migrate(config, azure))
        print('Both migration jobs succeeded. Local receipt recorded; runtime is a separate phase.')
    elif args.phase == 'runtime':
        verify_receipt(config, azure)
        assert_worker_transition(config, azure)
        result = deploy_template(config, azure, runtime=True)
        print(json.dumps(result, indent=2))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ConfigError, DeploymentError, OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
