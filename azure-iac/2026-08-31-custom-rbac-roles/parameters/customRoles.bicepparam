using '../modules/customRoles.bicep'

// Replace the placeholder subscription id below with the target subscription id before deploying.
var subscriptionScope = ['/subscriptions/00000000-0000-0000-0000-000000000000']

param roleDefinitions = [
  {
    roleName: 'Azure Platform Owner'
    description: 'Manages management groups and subscription lifecycles'
    actions: ['*']
    notActions: []
    dataActions: []
    notDataActions: []
    assignableScopes: subscriptionScope
  }
  {
    roleName: 'Subscription Owner'
    description: 'Delegated role for the subscription owner'
    actions: ['*']
    notActions: [
      'Microsoft.Authorization/*/write'
      'Microsoft.Network/vpnGateways/*'
      'Microsoft.Network/expressRouteCircuits/*'
      'Microsoft.Network/routeTables/write'
      'Microsoft.Network/vpnSites/*'
    ]
    dataActions: []
    notDataActions: []
    assignableScopes: subscriptionScope
  }
  {
    roleName: 'Application Owner'
    description: 'Contributor role for the application or operations team at the subscription scope (DevOps, App operations)'
    actions: ['*']
    notActions: [
      'Microsoft.Authorization/*/write'
      'Microsoft.Network/publicIPAddresses/write'
      'Microsoft.Network/virtualNetworks/write'
      'Microsoft.KeyVault/locations/deletedVaults/purge/action'
    ]
    dataActions: []
    notDataActions: []
    assignableScopes: subscriptionScope
  }
  {
    roleName: 'Network Management'
    description: 'Manages platform-wide global connectivity, such as virtual networks, UDRs, NSGs, NVAs, VPNs, Azure ExpressRoute, and others (NetOps)'
    actions: [
      '*/read'
      'Microsoft.Network/*'
      'Microsoft.Resources/deployments/*'
      'Microsoft.Support/*'
    ]
    notActions: []
    dataActions: []
    notDataActions: []
    assignableScopes: subscriptionScope
  }
  {
    roleName: 'Security Operations'
    description: 'Security Administrator role with a horizontal view across the entire Azure estate and the Key Vault purge policy (SecOps)'
    actions: [
      '*/read'
      '*/register/action'
      'Microsoft.KeyVault/locations/deletedVaults/purge/action'
      'Microsoft.PolicyInsights/*'
      'Microsoft.Authorization/policyAssignments/*'
      'Microsoft.Authorization/policyDefinitions/*'
      'Microsoft.Authorization/policyExemptions/*'
      'Microsoft.Authorization/policySetDefinitions/*'
      'Microsoft.Insights/alertRules/*'
      'Microsoft.Resources/deployments/*'
      'Microsoft.Security/*'
      'Microsoft.Support/*'
    ]
    notActions: []
    dataActions: []
    notDataActions: []
    assignableScopes: subscriptionScope
  }
]
