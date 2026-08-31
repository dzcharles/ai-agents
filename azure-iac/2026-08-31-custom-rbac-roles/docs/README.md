# Custom Azure RBAC Roles

Deploys 5 custom Azure RBAC role definitions at **subscription scope** via a Bicep module, applied as an **Azure Deployment Stack**.

## Roles Deployed

| Role Name | Description |
|---|---|
| Azure Platform Owner | Manages management groups and subscription lifecycles |
| Subscription Owner | Delegated role for the subscription owner |
| Application Owner | Contributor role for the application or operations team at the subscription scope (DevOps, App operations) |
| Network Management | Manages platform-wide global connectivity, such as virtual networks, UDRs, NSGs, NVAs, VPNs, Azure ExpressRoute, and others (NetOps) |
| Security Operations | Security Administrator role with a horizontal view across the entire Azure estate and the Key Vault purge policy (SecOps) |

## Folder Layout

```text
2026-08-31-custom-rbac-roles/
├── bicepconfig.json          # Bicep linter/config settings
├── modules/
│   └── customRoles.bicep     # Role definition module (subscription scope)
├── parameters/
│   └── customRoles.bicepparam
├── pipelines/
│   └── deploy-custom-roles.yml
└── docs/
    └── README.md              # this file
```

## Prerequisite

[customRoles.bicepparam](../parameters/customRoles.bicepparam) contains a placeholder subscription id:

```bicep
var subscriptionScope = ['/subscriptions/00000000-0000-0000-0000-000000000000']
```

Replace `00000000-0000-0000-0000-000000000000` with the real target subscription id before deploying.

## Manual Deployment

Deploy using [Azure Deployment Stacks](https://learn.microsoft.com/azure/azure-resource-manager/bicep/deployment-stacks):

```bash
az stack sub create \
  --name DeployCustomRbacRoles \
  --subscription <subscription-id> \
  --location <region> \
  --template-file azure-iac/2026-08-31-custom-rbac-roles/modules/customRoles.bicep \
  --parameters azure-iac/2026-08-31-custom-rbac-roles/parameters/customRoles.bicepparam \
  --deny-settings-mode DenyDelete \
  --action-on-unmanage DeleteAll \
  --validation-level Provider
```

## Pipeline

[deploy-custom-roles.yml](../pipelines/deploy-custom-roles.yml) is manual/PR-only:

- `trigger: none` — no CI trigger on push.
- PR validation runs automatically for pull requests targeting `main` that touch `modules/*.bicep` or `parameters/*.bicepparam`.

### Stages

| Stage | Purpose |
|---|---|
| `BicepLintChecks` | `az bicep build` to lint/compile the template |
| `ValidateDeployment` | `az stack sub validate` (RBAC/preflight) |
| `WhatIfDeployment` | `az stack-whatif sub create`, then deletes the resulting what-if stack (custom role definitions are low-volume/high-impact, so no stack is left lingering) |
| `DeployBicep` | `az stack sub create` — the actual deployment |

`DeployBicep` is gated behind the **`prd`** Azure DevOps environment (requires approval checks configured on that environment) and only runs when:

- the build reason is not `PullRequest`, **and**
- the source branch is `refs/heads/main`.

### Required Pipeline Parameters

Supply at queue time:

| Parameter | Description | Default |
|---|---|---|
| `azureServiceConnection` | ARM service connection using workload identity federation (no stored secret) | — |
| `subscriptionId` | Target subscription id | — |
| `location` | Deployment region | `westeurope` |

## Idempotency

- Each role definition's name is `guid(subscription().id, role.roleName)` — deterministic per role name. Redeploying with changed `actions`/`notActions` updates the existing role in place rather than creating a duplicate.
- Because deployment uses a **deployment stack**, any role definitions previously managed by the stack but removed from the template are cleaned up automatically, per the `--action-on-unmanage DeleteAll` setting.
