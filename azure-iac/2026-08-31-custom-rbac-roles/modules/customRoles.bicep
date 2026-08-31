targetScope = 'subscription'

@description('Array of custom RBAC role definitions to create. Each object requires roleName, description, actions, notActions, dataActions, notDataActions, and assignableScopes.')
param roleDefinitions array

resource customRoleDefinitions 'Microsoft.Authorization/roleDefinitions@2022-04-01' = [
  for role in roleDefinitions: {
    name: guid(subscription().id, role.roleName)
    scope: subscription()
    properties: {
      roleName: role.roleName
      description: role.description
      type: 'CustomRole'
      permissions: [
        {
          actions: role.actions
          notActions: role.notActions
          dataActions: role.dataActions
          notDataActions: role.notDataActions
        }
      ]
      assignableScopes: role.assignableScopes
    }
  }
]

@description('The resource ids and names of the created custom role definitions.')
output roleDefinitionIds array = [
  for (role, i) in roleDefinitions: {
    id: customRoleDefinitions[i].id
    roleName: role.roleName
  }
]
