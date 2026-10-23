targetScope = 'resourceGroup'

@minLength(3)
@maxLength(12)
param prefix string
param location string
param environmentName string
param environmentResourceGroup string = resourceGroup().name
param registryName string
param registryResourceGroup string = resourceGroup().name
param vaultName string
param vaultResourceGroup string = resourceGroup().name
param cloudIdentityName string
param cloudIdentityResourceGroup string = resourceGroup().name
param workloadProfileName string = ''
@description('Stage jobs first; run both successfully before deploying runtime.')
param deployRuntime bool = false
param deploymentFingerprint string
param images {
  python: string
  dashboard: string
  identity: string
  portal: string
}
param entra {
  tenantId: string
  portalClientId: string
  audience: string
  apiScope: string
}
@description('Leave empty to use the generated external portal FQDN. HTTPS custom domains must be bound separately.')
param portalPublicUrl string = ''
param portalDomain {
  hostname: string
  certificateId: string
}
param portalAllowedCidrs string[] = []
@minValue(1)
param keyPepperVersion int = 1
param features {
  scheduledScans: bool
  automatedAlerts: bool
  interactiveJobs: bool
  delivery: bool
  ai: bool
  gitopsPublish: bool
}
param workers {
  scan: bool
  scheduler: bool
  dispatcher: bool
}
param backendConfig object = {}
@description('Only explicitly verified ACA proxy CIDRs; empty does not trust forwarded client IP headers.')
param trustedProxyCidrs string[] = []
param extraSecrets array = []
param secretNames {
  cloudDatabaseUrl: string
  cloudRedisGatewayUrl: string
  cloudRedisWorkerUrl: string
  gatewayCallerToken: string
  tenantCallerToken: string
  scannerCallerToken: string
  analyticsCallerToken: string
  notificationCallerToken: string
  identityDatabaseUrl: string
  identityRedisUrl: string
  workspaceKeyPepper: string
  identityCallerDigests: string
  portalCallerToken: string
  portalEntraClientSecret: string
  cloudMigrationUrl: string
  identityMigrationUrl: string
}

resource environment 'Microsoft.App/managedEnvironments@2025-01-01' existing = {
  name: environmentName
  scope: resourceGroup(environmentResourceGroup)
}
resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: registryName
  scope: resourceGroup(registryResourceGroup)
}
resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: vaultName
  scope: resourceGroup(vaultResourceGroup)
}
resource cloudIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: cloudIdentityName
  scope: resourceGroup(cloudIdentityResourceGroup)
}
var tags = {
  application: 'cloudsaver'
  managedBy: 'cloudsaver-containerapps'
  deploymentFingerprint: deploymentFingerprint
}
var specs = [
  {
    name: 'identity'
    secrets: ['identityDatabaseUrl', 'identityRedisUrl', 'workspaceKeyPepper', 'identityCallerDigests']
  }
  { name: 'portal', secrets: ['portalCallerToken', 'portalEntraClientSecret'] }
  { name: 'scanner', secrets: ['cloudDatabaseUrl', 'cloudRedisWorkerUrl', 'scannerCallerToken'] }
  { name: 'tenant', secrets: ['cloudDatabaseUrl', 'cloudRedisWorkerUrl', 'tenantCallerToken'] }
  { name: 'analytics', secrets: ['cloudDatabaseUrl', 'cloudRedisWorkerUrl', 'analyticsCallerToken'] }
  { name: 'notifications', secrets: ['cloudDatabaseUrl', 'cloudRedisWorkerUrl', 'notificationCallerToken'] }
  { name: 'gateway', secrets: ['cloudDatabaseUrl', 'cloudRedisGatewayUrl', 'gatewayCallerToken'] }
  { name: 'dashboard', secrets: [] }
  { name: 'worker', secrets: ['cloudDatabaseUrl', 'cloudRedisWorkerUrl'] }
  { name: 'scheduler', secrets: ['cloudDatabaseUrl', 'cloudRedisWorkerUrl'] }
  { name: 'dispatcher', secrets: ['cloudDatabaseUrl', 'cloudRedisWorkerUrl'] }
  { name: 'migrate-cloud', secrets: ['cloudMigrationUrl'] }
  { name: 'migrate-platform', secrets: ['identityMigrationUrl'] }
]
resource identities 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = [
  for spec in specs: {
    name: '${prefix}-${spec.name}-config'
    location: location
    tags: tags
  }
]
module registryAccess './modules/registry-access.bicep' = {
  name: '${prefix}-registry-access'
  scope: resourceGroup(registryResourceGroup)
  params: { registryName: registryName, principalIds: [for (_, i) in specs: identities[i].properties.principalId] }
}
module vaultAccess './modules/vault-access.bicep' = [
  for (spec, i) in specs: {
    name: '${prefix}-vault-${spec.name}'
    scope: resourceGroup(vaultResourceGroup)
    params: {
      vaultName: vaultName
      principalId: identities[i].properties.principalId
      secretNames: union(
        map(spec.secrets, key => secretNames[key]),
        map(filter(extraSecrets, b => b.workload == spec.name), binding => binding.keyVaultSecretName)
      )
    }
  }
]
var vaultUri = vault.properties.vaultUri
var userConfig = [for pair in items(backendConfig): { name: pair.key, value: string(pair.value) }]
var cloudBaseEnv = [
  { name: 'CLOUDSAVER_ENVIRONMENT', value: 'production' }
  { name: 'CLOUDSAVER_MODE', value: 'azure' }
  { name: 'CLOUDSAVER_AUTH_MODE', value: 'workspace' }
  { name: 'CLOUDSAVER_TENANT_REGISTRY', value: 'database' }
  { name: 'CLOUDSAVER_TENANTS', value: '[]' }
  { name: 'CLOUDSAVER_KEY_VERIFIER', value: 'identity' }
  { name: 'CLOUDSAVER_DIRECTORY_MODE', value: 'cutover' }
  { name: 'CLOUDSAVER_PROVIDER_SCOPED_KEYS', value: 'true' }
  { name: 'CLOUDSAVER_CLOUD_IDENTITY', value: 'managed_identity' }
  { name: 'CLOUDSAVER_DISTRIBUTED_SCAN_LOCK', value: 'true' }
  { name: 'CLOUDSAVER_SCHEDULED_SCANS', value: string(features.scheduledScans) }
  { name: 'CLOUDSAVER_AUTOMATED_ALERTS', value: string(features.automatedAlerts) }
  { name: 'CLOUDSAVER_INTERACTIVE_JOBS', value: string(features.interactiveJobs) }
  { name: 'CLOUDSAVER_DELIVERY_ENABLED', value: string(features.delivery) }
  { name: 'CLOUDSAVER_AI_ENABLED', value: string(features.ai) }
  { name: 'CLOUDSAVER_GITOPS_PUBLISH', value: string(features.gitopsPublish) }
  { name: 'CLOUDSAVER_TRUSTED_CALLERS', value: '' }
  { name: 'CLOUDSAVER_TRUSTED_PROXIES', value: join(trustedProxyCidrs, ',') }
  { name: 'CLOUDSAVER_DB_POOL_SIZE', value: '2' }
  { name: 'CLOUDSAVER_DB_MAX_OVERFLOW', value: '3' }
]

module identity './modules/app.bicep' = if (deployRuntime) {
  name: '${prefix}-app-identity'
  params: {
    appName: '${prefix}-identity'
    location: location
    environmentId: environment.id
    registryServer: registry.properties.loginServer
    configIdentityId: identities[0].id
    image: images.identity
    command: ['uvicorn', 'identity.app:create_app', '--factory', '--host', '0.0.0.0', '--port', '8005']
    tags: tags
    workloadProfileName: workloadProfileName
    targetPort: 8005
    external: false
    minReplicas: 2
    maxReplicas: 4
    env: concat(
      [
        {
          name: 'PLATFORM_PUBLIC_URL'
          value: empty(portalPublicUrl)
            ? 'https://${prefix}-portal.${environment.properties.defaultDomain}'
            : portalPublicUrl
        }
        { name: 'PLATFORM_KEY_PEPPER_VERSION', value: string(keyPepperVersion) }
        { name: 'PLATFORM_ENVIRONMENT', value: 'production' }
        { name: 'PLATFORM_PORTAL_AUTH', value: 'entra' }
        { name: 'PLATFORM_OPERATOR_TENANT_ID', value: entra.tenantId }
        { name: 'PLATFORM_IDENTITY_AUDIENCE', value: entra.audience }
        { name: 'PLATFORM_PROVIDER_SCOPED_KEYS', value: 'true' }
        { name: 'PLATFORM_IDENTITY_CACHE_SECONDS', value: '15' }
        { name: 'PLATFORM_BILLING_ENABLED', value: 'false' }
        { name: 'PLATFORM_BILLING_PROVIDER', value: 'manual' }
        { name: 'PLATFORM_IDENTITY_DATABASE_URL', secretRef: 'identitydatabaseurl' }
        { name: 'PLATFORM_REDIS_URL', secretRef: 'identityredisurl' }
        { name: 'PLATFORM_KEY_PEPPER', secretRef: 'workspacekeypepper' }
        { name: 'PLATFORM_IDENTITY_CALLERS', secretRef: 'identitycallerdigests' }
      ],
      map(
        filter(extraSecrets, b => b.workload == 'identity'),
        binding => ({ name: binding.envName, secretRef: binding.appSecretName })
      )
    )
    secretBindings: concat(
      [
        { name: 'identitydatabaseurl', keyVaultUrl: '${vaultUri}secrets/${secretNames.identityDatabaseUrl}' }
        { name: 'identityredisurl', keyVaultUrl: '${vaultUri}secrets/${secretNames.identityRedisUrl}' }
        { name: 'workspacekeypepper', keyVaultUrl: '${vaultUri}secrets/${secretNames.workspaceKeyPepper}' }
        { name: 'identitycallerdigests', keyVaultUrl: '${vaultUri}secrets/${secretNames.identityCallerDigests}' }
      ],
      map(
        filter(extraSecrets, b => b.workload == 'identity'),
        binding => ({ name: binding.appSecretName, keyVaultUrl: '${vaultUri}secrets/${binding.keyVaultSecretName}' })
      )
    )
  }
  dependsOn: [registryAccess, vaultAccess]
}

module portal './modules/app.bicep' = if (deployRuntime) {
  name: '${prefix}-app-portal'
  params: {
    appName: '${prefix}-portal'
    location: location
    environmentId: environment.id
    registryServer: registry.properties.loginServer
    configIdentityId: identities[1].id
    image: images.portal
    command: []
    tags: tags
    workloadProfileName: workloadProfileName
    targetPort: 3100
    external: true
    minReplicas: 1
    maxReplicas: 1
    stickySessions: true
    customDomain: portalDomain
    ingressAllowedCidrs: portalAllowedCidrs
    livenessPath: '/api/healthz'
    readinessPath: '/api/healthz'
    env: concat(
      [
        { name: 'IDENTITY_SERVICE_URL', value: deployRuntime ? identity!.outputs.url : '' }
        { name: 'PLATFORM_ENVIRONMENT', value: 'production' }
        { name: 'PLATFORM_PORTAL_AUTH', value: 'entra' }
        {
          name: 'PORTAL_PUBLIC_URL'
          value: empty(portalPublicUrl)
            ? 'https://${prefix}-portal.${environment.properties.defaultDomain}'
            : portalPublicUrl
        }
        { name: 'PORTAL_ENTRA_TENANT_ID', value: entra.tenantId }
        { name: 'PORTAL_ENTRA_CLIENT_ID', value: entra.portalClientId }
        { name: 'PORTAL_ENTRA_API_SCOPE', value: entra.apiScope }
        { name: 'PLATFORM_PORTAL_TOKEN', secretRef: 'portalcallertoken' }
        { name: 'PORTAL_ENTRA_CLIENT_SECRET', secretRef: 'portalentraclientsecret' }
      ],
      map(
        filter(extraSecrets, b => b.workload == 'portal'),
        binding => ({ name: binding.envName, secretRef: binding.appSecretName })
      )
    )
    secretBindings: concat(
      [
        { name: 'portalcallertoken', keyVaultUrl: '${vaultUri}secrets/${secretNames.portalCallerToken}' }
        { name: 'portalentraclientsecret', keyVaultUrl: '${vaultUri}secrets/${secretNames.portalEntraClientSecret}' }
      ],
      map(
        filter(extraSecrets, b => b.workload == 'portal'),
        binding => ({ name: binding.appSecretName, keyVaultUrl: '${vaultUri}secrets/${binding.keyVaultSecretName}' })
      )
    )
  }
  dependsOn: [registryAccess, vaultAccess]
}

module scanner './modules/app.bicep' = if (deployRuntime) {
  name: '${prefix}-app-scanner'
  params: {
    appName: '${prefix}-scanner'
    location: location
    environmentId: environment.id
    registryServer: registry.properties.loginServer
    configIdentityId: identities[2].id
    image: images.python
    command: [
      'uvicorn'
      'services.scanner:create_app'
      '--factory'
      '--host'
      '0.0.0.0'
      '--port'
      '8002'
      '--workers'
      '1'
    ]
    tags: tags
    workloadProfileName: workloadProfileName
    targetPort: 8002
    external: false
    minReplicas: 1
    maxReplicas: 1
    cloudIdentityId: cloudIdentity.id
    env: concat(
      concat(cloudBaseEnv, userConfig, [
        { name: 'CLOUDSAVER_IDENTITY_URL', value: deployRuntime ? identity!.outputs.url : '' }
        { name: 'AZURE_CLIENT_ID', value: cloudIdentity.properties.clientId }
        { name: 'CLOUDSAVER_DATABASE_URL', secretRef: 'clouddatabaseurl' }
        { name: 'REDIS_URL', secretRef: 'cloudredisworkerurl' }
        { name: 'CLOUDSAVER_IDENTITY_TOKEN', secretRef: 'scannercallertoken' }
      ]),
      map(
        filter(extraSecrets, b => b.workload == 'scanner'),
        binding => ({ name: binding.envName, secretRef: binding.appSecretName })
      )
    )
    secretBindings: concat(
      [
        { name: 'clouddatabaseurl', keyVaultUrl: '${vaultUri}secrets/${secretNames.cloudDatabaseUrl}' }
        { name: 'cloudredisworkerurl', keyVaultUrl: '${vaultUri}secrets/${secretNames.cloudRedisWorkerUrl}' }
        { name: 'scannercallertoken', keyVaultUrl: '${vaultUri}secrets/${secretNames.scannerCallerToken}' }
      ],
      map(
        filter(extraSecrets, b => b.workload == 'scanner'),
        binding => ({ name: binding.appSecretName, keyVaultUrl: '${vaultUri}secrets/${binding.keyVaultSecretName}' })
      )
    )
  }
  dependsOn: [registryAccess, vaultAccess]
}

module tenant './modules/app.bicep' = if (deployRuntime) {
  name: '${prefix}-app-tenant'
  params: {
    appName: '${prefix}-tenant'
    location: location
    environmentId: environment.id
    registryServer: registry.properties.loginServer
    configIdentityId: identities[3].id
    image: images.python
    command: ['uvicorn', 'services.tenant:create_app', '--factory', '--host', '0.0.0.0', '--port', '8001']
    tags: tags
    workloadProfileName: workloadProfileName
    targetPort: 8001
    external: false
    minReplicas: 1
    maxReplicas: 1
    env: concat(
      concat(cloudBaseEnv, userConfig, [
        { name: 'CLOUDSAVER_IDENTITY_URL', value: deployRuntime ? identity!.outputs.url : '' }
        { name: 'CLOUDSAVER_DATABASE_URL', secretRef: 'clouddatabaseurl' }
        { name: 'REDIS_URL', secretRef: 'cloudredisworkerurl' }
        { name: 'CLOUDSAVER_IDENTITY_TOKEN', secretRef: 'tenantcallertoken' }
      ]),
      map(
        filter(extraSecrets, b => b.workload == 'tenant'),
        binding => ({ name: binding.envName, secretRef: binding.appSecretName })
      )
    )
    secretBindings: concat(
      [
        { name: 'clouddatabaseurl', keyVaultUrl: '${vaultUri}secrets/${secretNames.cloudDatabaseUrl}' }
        { name: 'cloudredisworkerurl', keyVaultUrl: '${vaultUri}secrets/${secretNames.cloudRedisWorkerUrl}' }
        { name: 'tenantcallertoken', keyVaultUrl: '${vaultUri}secrets/${secretNames.tenantCallerToken}' }
      ],
      map(
        filter(extraSecrets, b => b.workload == 'tenant'),
        binding => ({ name: binding.appSecretName, keyVaultUrl: '${vaultUri}secrets/${binding.keyVaultSecretName}' })
      )
    )
  }
  dependsOn: [registryAccess, vaultAccess]
}

module analytics './modules/app.bicep' = if (deployRuntime) {
  name: '${prefix}-app-analytics'
  params: {
    appName: '${prefix}-analytics'
    location: location
    environmentId: environment.id
    registryServer: registry.properties.loginServer
    configIdentityId: identities[4].id
    image: images.python
    command: ['uvicorn', 'services.analytics:create_app', '--factory', '--host', '0.0.0.0', '--port', '8003']
    tags: tags
    workloadProfileName: workloadProfileName
    targetPort: 8003
    external: false
    minReplicas: 2
    maxReplicas: 4
    env: concat(
      concat(cloudBaseEnv, userConfig, [
        { name: 'CLOUDSAVER_IDENTITY_URL', value: deployRuntime ? identity!.outputs.url : '' }
        { name: 'SCANNER_SERVICE_URL', value: deployRuntime ? scanner!.outputs.url : '' }
        { name: 'CLOUDSAVER_DATABASE_URL', secretRef: 'clouddatabaseurl' }
        { name: 'REDIS_URL', secretRef: 'cloudredisworkerurl' }
        { name: 'CLOUDSAVER_IDENTITY_TOKEN', secretRef: 'analyticscallertoken' }
      ]),
      map(
        filter(extraSecrets, b => b.workload == 'analytics'),
        binding => ({ name: binding.envName, secretRef: binding.appSecretName })
      )
    )
    secretBindings: concat(
      [
        { name: 'clouddatabaseurl', keyVaultUrl: '${vaultUri}secrets/${secretNames.cloudDatabaseUrl}' }
        { name: 'cloudredisworkerurl', keyVaultUrl: '${vaultUri}secrets/${secretNames.cloudRedisWorkerUrl}' }
        { name: 'analyticscallertoken', keyVaultUrl: '${vaultUri}secrets/${secretNames.analyticsCallerToken}' }
      ],
      map(
        filter(extraSecrets, b => b.workload == 'analytics'),
        binding => ({ name: binding.appSecretName, keyVaultUrl: '${vaultUri}secrets/${binding.keyVaultSecretName}' })
      )
    )
  }
  dependsOn: [registryAccess, vaultAccess]
}

module notifications './modules/app.bicep' = if (deployRuntime) {
  name: '${prefix}-app-notifications'
  params: {
    appName: '${prefix}-notifications'
    location: location
    environmentId: environment.id
    registryServer: registry.properties.loginServer
    configIdentityId: identities[5].id
    image: images.python
    command: ['uvicorn', 'services.notification:create_app', '--factory', '--host', '0.0.0.0', '--port', '8004']
    tags: tags
    workloadProfileName: workloadProfileName
    targetPort: 8004
    external: false
    minReplicas: 2
    maxReplicas: 4
    env: concat(
      concat(cloudBaseEnv, userConfig, [
        { name: 'CLOUDSAVER_IDENTITY_URL', value: deployRuntime ? identity!.outputs.url : '' }
        { name: 'SCANNER_SERVICE_URL', value: deployRuntime ? scanner!.outputs.url : '' }
        { name: 'CLOUDSAVER_DATABASE_URL', secretRef: 'clouddatabaseurl' }
        { name: 'REDIS_URL', secretRef: 'cloudredisworkerurl' }
        { name: 'CLOUDSAVER_IDENTITY_TOKEN', secretRef: 'notificationcallertoken' }
      ]),
      map(
        filter(extraSecrets, b => b.workload == 'notifications'),
        binding => ({ name: binding.envName, secretRef: binding.appSecretName })
      )
    )
    secretBindings: concat(
      [
        { name: 'clouddatabaseurl', keyVaultUrl: '${vaultUri}secrets/${secretNames.cloudDatabaseUrl}' }
        { name: 'cloudredisworkerurl', keyVaultUrl: '${vaultUri}secrets/${secretNames.cloudRedisWorkerUrl}' }
        { name: 'notificationcallertoken', keyVaultUrl: '${vaultUri}secrets/${secretNames.notificationCallerToken}' }
      ],
      map(
        filter(extraSecrets, b => b.workload == 'notifications'),
        binding => ({ name: binding.appSecretName, keyVaultUrl: '${vaultUri}secrets/${binding.keyVaultSecretName}' })
      )
    )
  }
  dependsOn: [registryAccess, vaultAccess]
}

module gateway './modules/app.bicep' = if (deployRuntime) {
  name: '${prefix}-app-gateway'
  params: {
    appName: '${prefix}-gateway'
    location: location
    environmentId: environment.id
    registryServer: registry.properties.loginServer
    configIdentityId: identities[6].id
    image: images.python
    command: ['uvicorn', 'services.gateway:create_app', '--factory', '--host', '0.0.0.0', '--port', '8000']
    tags: tags
    workloadProfileName: workloadProfileName
    targetPort: 8000
    external: false
    minReplicas: 2
    maxReplicas: 4
    env: concat(
      concat(cloudBaseEnv, userConfig, [
        { name: 'CLOUDSAVER_IDENTITY_URL', value: deployRuntime ? identity!.outputs.url : '' }
        { name: 'SCANNER_SERVICE_URL', value: deployRuntime ? scanner!.outputs.url : '' }
        { name: 'TENANT_SERVICE_URL', value: deployRuntime ? tenant!.outputs.url : '' }
        { name: 'ANALYTICS_SERVICE_URL', value: deployRuntime ? analytics!.outputs.url : '' }
        { name: 'NOTIFICATION_SERVICE_URL', value: deployRuntime ? notifications!.outputs.url : '' }
        { name: 'CLOUDSAVER_DATABASE_URL', secretRef: 'clouddatabaseurl' }
        { name: 'REDIS_URL', secretRef: 'cloudredisgatewayurl' }
        { name: 'CLOUDSAVER_IDENTITY_TOKEN', secretRef: 'gatewaycallertoken' }
      ]),
      map(
        filter(extraSecrets, b => b.workload == 'gateway'),
        binding => ({ name: binding.envName, secretRef: binding.appSecretName })
      )
    )
    secretBindings: concat(
      [
        { name: 'clouddatabaseurl', keyVaultUrl: '${vaultUri}secrets/${secretNames.cloudDatabaseUrl}' }
        { name: 'cloudredisgatewayurl', keyVaultUrl: '${vaultUri}secrets/${secretNames.cloudRedisGatewayUrl}' }
        { name: 'gatewaycallertoken', keyVaultUrl: '${vaultUri}secrets/${secretNames.gatewayCallerToken}' }
      ],
      map(
        filter(extraSecrets, b => b.workload == 'gateway'),
        binding => ({ name: binding.appSecretName, keyVaultUrl: '${vaultUri}secrets/${binding.keyVaultSecretName}' })
      )
    )
  }
  dependsOn: [registryAccess, vaultAccess]
}

module dashboard './modules/app.bicep' = if (deployRuntime) {
  name: '${prefix}-app-dashboard'
  params: {
    appName: '${prefix}-dashboard'
    location: location
    environmentId: environment.id
    registryServer: registry.properties.loginServer
    configIdentityId: identities[7].id
    image: images.dashboard
    command: []
    tags: tags
    workloadProfileName: workloadProfileName
    targetPort: 3000
    external: true
    minReplicas: 2
    maxReplicas: 4
    livenessPath: '/'
    readinessPath: '/'
    env: concat(
      [
        { name: 'API_GATEWAY_URL', value: deployRuntime ? gateway!.outputs.url : '' }
      ],
      map(
        filter(extraSecrets, b => b.workload == 'dashboard'),
        binding => ({ name: binding.envName, secretRef: binding.appSecretName })
      )
    )
    secretBindings: concat(
      [],
      map(
        filter(extraSecrets, b => b.workload == 'dashboard'),
        binding => ({ name: binding.appSecretName, keyVaultUrl: '${vaultUri}secrets/${binding.keyVaultSecretName}' })
      )
    )
  }
  dependsOn: [registryAccess, vaultAccess]
}

module worker './modules/app.bicep' = if (deployRuntime && workers.scan) {
  name: '${prefix}-app-worker'
  params: {
    appName: '${prefix}-worker'
    location: location
    environmentId: environment.id
    registryServer: registry.properties.loginServer
    configIdentityId: identities[8].id
    image: images.python
    command: ['celery', '-A', 'workers.tasks:celery_app', 'worker', '--loglevel=WARNING', '--concurrency=1']
    tags: tags
    workloadProfileName: workloadProfileName
    targetPort: 0
    external: false
    minReplicas: 1
    maxReplicas: 1
    cloudIdentityId: cloudIdentity.id
    terminationGracePeriodSeconds: 600
    env: concat(
      concat(cloudBaseEnv, userConfig, [
        { name: 'CLOUDSAVER_IDENTITY_URL', value: deployRuntime ? identity!.outputs.url : '' }
        { name: 'AZURE_CLIENT_ID', value: cloudIdentity.properties.clientId }
        { name: 'CLOUDSAVER_DATABASE_URL', secretRef: 'clouddatabaseurl' }
        { name: 'REDIS_URL', secretRef: 'cloudredisworkerurl' }
      ]),
      map(
        filter(extraSecrets, b => b.workload == 'worker'),
        binding => ({ name: binding.envName, secretRef: binding.appSecretName })
      )
    )
    secretBindings: concat(
      [
        { name: 'clouddatabaseurl', keyVaultUrl: '${vaultUri}secrets/${secretNames.cloudDatabaseUrl}' }
        { name: 'cloudredisworkerurl', keyVaultUrl: '${vaultUri}secrets/${secretNames.cloudRedisWorkerUrl}' }
      ],
      map(
        filter(extraSecrets, b => b.workload == 'worker'),
        binding => ({ name: binding.appSecretName, keyVaultUrl: '${vaultUri}secrets/${binding.keyVaultSecretName}' })
      )
    )
  }
  dependsOn: [registryAccess, vaultAccess]
}

module scheduler './modules/app.bicep' = if (deployRuntime && workers.scheduler) {
  name: '${prefix}-app-scheduler'
  params: {
    appName: '${prefix}-scheduler'
    location: location
    environmentId: environment.id
    registryServer: registry.properties.loginServer
    configIdentityId: identities[9].id
    image: images.python
    command: [
      'celery'
      '-A'
      'workers.tasks:celery_app'
      'beat'
      '--loglevel=WARNING'
      '--schedule=/tmp/celerybeat-schedule'
    ]
    tags: tags
    workloadProfileName: workloadProfileName
    targetPort: 0
    external: false
    minReplicas: 1
    maxReplicas: 1
    env: concat(
      concat(cloudBaseEnv, userConfig, [
        { name: 'CLOUDSAVER_IDENTITY_URL', value: deployRuntime ? identity!.outputs.url : '' }
        { name: 'CLOUDSAVER_DATABASE_URL', secretRef: 'clouddatabaseurl' }
        { name: 'REDIS_URL', secretRef: 'cloudredisworkerurl' }
      ]),
      map(
        filter(extraSecrets, b => b.workload == 'scheduler'),
        binding => ({ name: binding.envName, secretRef: binding.appSecretName })
      )
    )
    secretBindings: concat(
      [
        { name: 'clouddatabaseurl', keyVaultUrl: '${vaultUri}secrets/${secretNames.cloudDatabaseUrl}' }
        { name: 'cloudredisworkerurl', keyVaultUrl: '${vaultUri}secrets/${secretNames.cloudRedisWorkerUrl}' }
      ],
      map(
        filter(extraSecrets, b => b.workload == 'scheduler'),
        binding => ({ name: binding.appSecretName, keyVaultUrl: '${vaultUri}secrets/${binding.keyVaultSecretName}' })
      )
    )
  }
  dependsOn: [registryAccess, vaultAccess]
}

module dispatcher './modules/app.bicep' = if (deployRuntime && workers.dispatcher) {
  name: '${prefix}-app-dispatcher'
  params: {
    appName: '${prefix}-dispatcher'
    location: location
    environmentId: environment.id
    registryServer: registry.properties.loginServer
    configIdentityId: identities[10].id
    image: images.python
    command: ['python', '-m', 'workers.dispatcher']
    tags: tags
    workloadProfileName: workloadProfileName
    targetPort: 0
    external: false
    minReplicas: 1
    maxReplicas: 1
    env: concat(
      concat(cloudBaseEnv, userConfig, [
        { name: 'CLOUDSAVER_IDENTITY_URL', value: deployRuntime ? identity!.outputs.url : '' }
        { name: 'CLOUDSAVER_DATABASE_URL', secretRef: 'clouddatabaseurl' }
        { name: 'REDIS_URL', secretRef: 'cloudredisworkerurl' }
      ]),
      map(
        filter(extraSecrets, b => b.workload == 'dispatcher'),
        binding => ({ name: binding.envName, secretRef: binding.appSecretName })
      )
    )
    secretBindings: concat(
      [
        { name: 'clouddatabaseurl', keyVaultUrl: '${vaultUri}secrets/${secretNames.cloudDatabaseUrl}' }
        { name: 'cloudredisworkerurl', keyVaultUrl: '${vaultUri}secrets/${secretNames.cloudRedisWorkerUrl}' }
      ],
      map(
        filter(extraSecrets, b => b.workload == 'dispatcher'),
        binding => ({ name: binding.appSecretName, keyVaultUrl: '${vaultUri}secrets/${binding.keyVaultSecretName}' })
      )
    )
  }
  dependsOn: [registryAccess, vaultAccess]
}

module migrateplatform './modules/job.bicep' = {
  name: '${prefix}-job-migrate-platform'
  params: {
    jobName: '${prefix}-migrate-platform'
    location: location
    environmentId: environment.id
    registryServer: registry.properties.loginServer
    identityId: identities[12].id
    image: images.identity
    command: ['python', '-m', 'alembic', '-c', 'identity_alembic.ini', 'upgrade', 'head']
    envName: 'PLATFORM_IDENTITY_MIGRATION_URL'
    keyVaultSecretUrl: '${vaultUri}secrets/${secretNames.identityMigrationUrl}'
    tags: tags
    workloadProfileName: workloadProfileName
  }
  dependsOn: [registryAccess, vaultAccess]
}

module migratecloud './modules/job.bicep' = {
  name: '${prefix}-job-migrate-cloud'
  params: {
    jobName: '${prefix}-migrate-cloud'
    location: location
    environmentId: environment.id
    registryServer: registry.properties.loginServer
    identityId: identities[11].id
    image: images.python
    command: ['python', '-m', 'alembic', 'upgrade', 'head']
    envName: 'CLOUDSAVER_MIGRATION_URL'
    keyVaultSecretUrl: '${vaultUri}secrets/${secretNames.cloudMigrationUrl}'
    tags: tags
    workloadProfileName: workloadProfileName
  }
  dependsOn: [registryAccess, vaultAccess]
}

output environmentId string = environment.id
output migrationJobs object = { platform: migrateplatform.outputs.name, cloudsaver: migratecloud.outputs.name }
output portalUrl string = deployRuntime ? portal!.outputs.url : ''
output dashboardUrl string = deployRuntime ? dashboard!.outputs.url : ''
