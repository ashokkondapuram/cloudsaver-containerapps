targetScope = 'resourceGroup'
param appName string
param location string
param environmentId string
param registryServer string
param configIdentityId string
param cloudIdentityId string = ''
param image string
param command string[] = []
param env array
param secretBindings array
param tags object
param targetPort int = 0
param external bool = false
param readinessPath string = '/readyz'
param livenessPath string = '/healthz'
param minReplicas int = 1
param maxReplicas int = 1
param workloadProfileName string = ''
param ingressAllowedCidrs string[] = []
param stickySessions bool = false
param customDomain {
  hostname: string
  certificateId: string
} = { hostname: '', certificateId: '' }
param terminationGracePeriodSeconds int = 45

var config = union(
  {
    activeRevisionsMode: 'Single'
    maxInactiveRevisions: 5
    registries: [{ server: registryServer, identity: configIdentityId }]
    secrets: map(
      secretBindings,
      binding =>
        ({
          name: binding.name
          keyVaultUrl: binding.keyVaultUrl
          identity: configIdentityId
        })
    )
  },
  targetPort > 0
    ? {
        ingress: union(
          {
            external: external
            targetPort: targetPort
            transport: 'http'
            allowInsecure: false
            traffic: [{ latestRevision: true, weight: 100 }]
            ipSecurityRestrictions: map(
              ingressAllowedCidrs,
              (cidr, i) =>
                ({
                  name: 'allow-${i}'
                  action: 'Allow'
                  ipAddressRange: cidr
                })
            )
          },
          stickySessions ? { stickySessions: { affinity: 'sticky' } } : {},
          empty(customDomain.hostname)
            ? {}
            : {
                customDomains: [
                  { name: customDomain.hostname, certificateId: customDomain.certificateId, bindingType: 'SniEnabled' }
                ]
              }
        )
      }
    : {}
)

resource app 'Microsoft.App/containerApps@2025-01-01' = {
  name: appName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: union(
      { '${configIdentityId}': {} },
      empty(cloudIdentityId) ? {} : { '${cloudIdentityId}': {} }
    )
  }
  properties: union(
    {
      managedEnvironmentId: environmentId
      configuration: config
      template: {
        terminationGracePeriodSeconds: terminationGracePeriodSeconds
        containers: [
          union(
            {
              name: 'app'
              image: image
              env: env
              resources: { cpu: json('0.5'), memory: '1Gi' }
            },
            empty(command) ? {} : { command: command },
            targetPort > 0
              ? {
                  probes: [
                    {
                      type: 'Startup'
                      httpGet: { path: livenessPath, port: targetPort, scheme: 'HTTP' }
                      periodSeconds: 5
                      timeoutSeconds: 5
                      failureThreshold: 60
                    }
                    {
                      type: 'Liveness'
                      httpGet: { path: livenessPath, port: targetPort, scheme: 'HTTP' }
                      periodSeconds: 15
                      timeoutSeconds: 5
                      failureThreshold: 3
                    }
                    {
                      type: 'Readiness'
                      httpGet: { path: readinessPath, port: targetPort, scheme: 'HTTP' }
                      periodSeconds: 10
                      timeoutSeconds: 10
                      failureThreshold: 3
                    }
                  ]
                }
              : {}
          )
        ]
        scale: {
          minReplicas: minReplicas
          maxReplicas: maxReplicas
          rules: maxReplicas > minReplicas && targetPort > 0
            ? [
                {
                  name: 'http-requests'
                  http: { metadata: { concurrentRequests: '50' } }
                }
              ]
            : []
        }
      }
    },
    empty(workloadProfileName) ? {} : { workloadProfileName: workloadProfileName }
  )
}
output id string = app.id
output url string = targetPort > 0 ? 'https://${app.properties.configuration.ingress.fqdn}' : ''
