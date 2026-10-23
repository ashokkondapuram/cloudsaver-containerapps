targetScope = 'resourceGroup'
param vaultName string
param principalId string
param secretNames string[]

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: vaultName
}
resource secrets 'Microsoft.KeyVault/vaults/secrets@2023-07-01' existing = [
  for secretName in secretNames: {
    parent: vault
    name: secretName
  }
]
var secretsUserRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '4633458b-17de-408a-b874-0445c86b69e6'
)
resource grants 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (secretName, i) in secretNames: {
    name: guid(secrets[i].id, principalId, secretsUserRoleId)
    scope: secrets[i]
    properties: {
      roleDefinitionId: secretsUserRoleId
      principalId: principalId
      principalType: 'ServicePrincipal'
    }
  }
]
