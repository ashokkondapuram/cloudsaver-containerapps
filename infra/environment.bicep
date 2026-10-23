targetScope = 'resourceGroup'
@minLength(3)
@maxLength(24)
param environmentName string
param location string = resourceGroup().location
@description('Dedicated, correctly delegated ACA infrastructure subnet in an existing VNet. Provision private DNS/routing separately.')
param infrastructureSubnetId string
@description('True makes the environment privately reachable through its VNet; configure DNS/VPN/front door separately.')
param internalEnvironment bool = true
param logRetentionDays int = 30

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${environmentName}-logs'
  location: location
  properties: {
    retentionInDays: logRetentionDays
    sku: { name: 'PerGB2018' }
  }
}
resource environment 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: environmentName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
    vnetConfiguration: {
      infrastructureSubnetId: infrastructureSubnetId
      internal: internalEnvironment
    }
    workloadProfiles: [{ name: 'Consumption', workloadProfileType: 'Consumption' }]
    zoneRedundant: false
  }
}
output environmentId string = environment.id
output defaultDomain string = environment.properties.defaultDomain
