targetScope = 'resourceGroup'
param jobName string
param location string
param environmentId string
param registryServer string
param identityId string
param image string
param command string[]
param envName string
param keyVaultSecretUrl string
param tags object
param workloadProfileName string = ''

var jobConfiguration = {
  triggerType: 'Manual'
  replicaTimeout: 900
  replicaRetryLimit: 0
  manualTriggerConfig: { parallelism: 1, replicaCompletionCount: 1 }
  registries: [{ server: registryServer, identity: identityId }]
  secrets: [{ name: 'owner-dsn', keyVaultUrl: keyVaultSecretUrl, identity: identityId }]
}
var jobTemplate = {
  containers: [
    {
      name: 'migrate'
      image: image
      command: command
      env: [{ name: envName, secretRef: 'owner-dsn' }]
      resources: { cpu: json('0.5'), memory: '1Gi' }
    }
  ]
}

resource job 'Microsoft.App/jobs@2025-01-01' = {
  name: jobName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identityId}': {} }
  }
  properties: union(
    {
      environmentId: environmentId
      configuration: jobConfiguration
      template: jobTemplate
    },
    empty(workloadProfileName) ? {} : { workloadProfileName: workloadProfileName }
  )
}
output name string = job.name
output id string = job.id
