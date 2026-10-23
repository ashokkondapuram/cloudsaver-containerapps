"""Validate non-secret configuration and enforce deployment invariants."""
from __future__ import annotations
import hashlib
import ipaddress
import json
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = json.loads((ROOT / 'examples/config.schema.json').read_text())
KNOWN_BLOCKED_REVISION = '6fc05bb3215a300bbec3b05218614dce35a4403d'

# Core credentials, endpoints, identity settings and feature flags are structural.
RESERVED = {
    'CLOUDSAVER_DATABASE_URL', 'CLOUDSAVER_MIGRATION_URL', 'REDIS_URL', 'CLOUDSAVER_IDENTITY_TOKEN',
    'CLOUDSAVER_ENVIRONMENT', 'CLOUDSAVER_MODE', 'CLOUDSAVER_AUTH_MODE', 'CLOUDSAVER_TENANT_REGISTRY',
    'CLOUDSAVER_TENANTS', 'CLOUDSAVER_KEY_VERIFIER', 'CLOUDSAVER_DIRECTORY_MODE', 'CLOUDSAVER_PROVIDER_SCOPED_KEYS',
    'CLOUDSAVER_CLOUD_IDENTITY', 'CLOUDSAVER_DISTRIBUTED_SCAN_LOCK', 'CLOUDSAVER_SCHEDULED_SCANS',
    'CLOUDSAVER_AUTOMATED_ALERTS', 'CLOUDSAVER_INTERACTIVE_JOBS', 'CLOUDSAVER_DELIVERY_ENABLED',
    'CLOUDSAVER_AI_ENABLED', 'CLOUDSAVER_GITOPS_PUBLISH', 'CLOUDSAVER_TRUSTED_CALLERS',
    'CLOUDSAVER_TRUSTED_PROXIES', 'CLOUDSAVER_IDENTITY_URL', 'AZURE_CLIENT_ID',
    'SCANNER_SERVICE_URL', 'TENANT_SERVICE_URL', 'ANALYTICS_SERVICE_URL', 'NOTIFICATION_SERVICE_URL',
    'API_GATEWAY_URL', 'CLOUDSAVER_DB_POOL_SIZE', 'CLOUDSAVER_DB_MAX_OVERFLOW',
    'PLATFORM_IDENTITY_DATABASE_URL', 'PLATFORM_IDENTITY_MIGRATION_URL', 'PLATFORM_REDIS_URL',
    'PLATFORM_KEY_PEPPER', 'PLATFORM_KEY_PEPPER_VERSION', 'PLATFORM_IDENTITY_CALLERS', 'PLATFORM_ENVIRONMENT', 'PLATFORM_PORTAL_AUTH',
    'PLATFORM_OPERATOR_TENANT_ID', 'PLATFORM_IDENTITY_AUDIENCE', 'PLATFORM_PROVIDER_SCOPED_KEYS',
    'PLATFORM_IDENTITY_CACHE_SECONDS', 'PLATFORM_BILLING_ENABLED', 'PLATFORM_BILLING_PROVIDER',
    'PLATFORM_PORTAL_TOKEN', 'IDENTITY_SERVICE_URL', 'PORTAL_PUBLIC_URL', 'PORTAL_ENTRA_TENANT_ID',
    'PORTAL_ENTRA_CLIENT_ID', 'PORTAL_ENTRA_API_SCOPE', 'PORTAL_ENTRA_CLIENT_SECRET',
}
CORE_LOCAL_SECRETS = {key.lower() for key in SCHEMA['properties']['secretNames']['required']}


class ConfigError(ValueError):
    pass


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ConfigError('Duplicate JSON field names are not allowed')
        value[key] = item
    return value


def load(path):
    if Path(path).stat().st_size > 1_000_000:
        raise ConfigError('Configuration exceeds 1 MB')
    try:
        config = json.loads(Path(path).read_text(), object_pairs_hook=unique_object)
    except (UnicodeError, json.JSONDecodeError):
        raise ConfigError('Configuration is not valid UTF-8 JSON') from None
    validate(config)
    return config


def validate(config):
    errors = sorted(Draft202012Validator(SCHEMA, format_checker=FormatChecker()).iter_errors(config),
                    key=lambda e: '/'.join(map(str, e.path)))
    if errors:
        error = errors[0]
        # Never echo submitted values: even misplaced credentials stay out of logs.
        raise ConfigError(f'Invalid configuration at {"/".join(map(str, error.path)) or "root"} ({error.validator})')
    if len(set(config['secretNames'].values())) != len(config['secretNames']):
        raise ConfigError('Every core credential must use an independent Key Vault secret name')
    for name in config['backendConfig']:
        if name in RESERVED:
            raise ConfigError('backendConfig cannot override structural environment variables')
        if any(part in name for part in ('PASSWORD', 'SECRET', 'PRIVATE_KEY', 'PEPPER', 'WEBHOOK', 'TOKEN')) and not name.endswith('TOKEN_AUDIENCE'):
            raise ConfigError('Credential variables must use explicit extraSecrets bindings')
        if name.startswith(('PLATFORM_', 'PORTAL_', 'IDENTITY_')):
            raise ConfigError('backendConfig applies only to CloudSaver backends')
    domain = config['portalDomain']
    if config['portalPublicUrl']:
        if not domain['hostname'] or not domain['certificateId'] or config['portalPublicUrl'] != 'https://' + domain['hostname']:
            raise ConfigError('Custom portal origin requires matching hostname and existing ACA certificate binding')
    elif domain['hostname'] or domain['certificateId']:
        raise ConfigError('Custom portal domain requires a matching public URL')
    seen_env, seen_secrets = set(), set()
    for binding in config['extraSecrets']:
        env_key = (binding['workload'], binding['envName'])
        secret_key = (binding['workload'], binding['appSecretName'])
        if binding['envName'] in RESERVED or binding['envName'] in config['backendConfig']:
            raise ConfigError('extraSecrets cannot override structural/configured environment variables')
        if binding['appSecretName'] in CORE_LOCAL_SECRETS:
            raise ConfigError('extraSecrets cannot replace a core secret reference')
        if env_key in seen_env or secret_key in seen_secrets:
            raise ConfigError('Duplicate extra secret/environment binding')
        if binding['keyVaultSecretName'] in config['secretNames'].values():
            raise ConfigError('Do not expose a core credential through an additional binding')
        seen_env.add(env_key)
        seen_secrets.add(secret_key)
    for field in ('trustedProxyCidrs', 'portalAllowedCidrs'):
        for item in config[field]:
            try:
                network = ipaddress.ip_network(item, strict=True)
            except ValueError:
                raise ConfigError(f'{field} requires canonical CIDR ranges') from None
            if field == 'trustedProxyCidrs' and network.prefixlen == 0:
                raise ConfigError('Never trust every source as a reverse proxy')
    f, w = config['features'], config['workers']
    if f['scheduledScans'] and not all(w.values()):
        raise ConfigError('Scheduled scans require all three worker components')
    if f['interactiveJobs'] and not (w['scan'] and w['dispatcher']):
        raise ConfigError('Interactive jobs require scan worker and dispatcher')
    if f['delivery'] and not w['dispatcher']:
        raise ConfigError('Delivery requires dispatcher')
    if f['automatedAlerts'] and not f['delivery']:
        raise ConfigError('Automated alerts require delivery')


def require_real_values(config):
    if config['subscriptionId'].replace('-', '') == '0' * 32:
        raise ConfigError('Replace the example subscription ID')
    if any(v.endswith('sha256:' + '0' * 64) for v in config['images'].values()):
        raise ConfigError('Replace placeholder image digests with published image digests')
    if any('REPLACE' in str(v) or str(v).replace('-', '') == '0' * 32 for v in config['entra'].values()):
        raise ConfigError('Replace the example Entra configuration')


def require_application_acceptance(config):
    app = config['application']
    if app['sourceRevision'] == KNOWN_BLOCKED_REVISION or not app['acceptanceRecord'].strip():
        raise ConfigError('Application startup/migration acceptance is required; see docs/COMPATIBILITY.md')


def fingerprint(config):
    digest = hashlib.sha256(json.dumps(config, sort_keys=True, separators=(',', ':')).encode())
    for path in sorted((ROOT / 'infra').rglob('*.bicep')):
        digest.update(path.relative_to(ROOT).as_posix().encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()


def parameters(config, runtime):
    value = {k: {'value': v} for k, v in config.items() if k not in ('subscriptionId', 'resourceGroup', 'application')}
    value['deployRuntime'] = {'value': runtime}
    value['deploymentFingerprint'] = {'value': fingerprint(config)}
    return {'$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#',
            'contentVersion': '1.0.0.0', 'parameters': value}
