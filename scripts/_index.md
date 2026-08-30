# Scripts index

| script | type | title | description | last updated |
| --- | --- | --- | --- | --- |
| [Get-AzVNetOverview.ps1](Get-AzVNetOverview.ps1) | powershell | Azure virtual network overview | Read-only report of the virtual networks in one or all enabled subscriptions: address space, subnet count, DNS servers, peerings, DDoS state and tags. Supports `-IncludeSubnetDetail` for per-subnet rows (prefix, NSG, route table, delegations, network policies, connected devices) and `-CsvPath` for CSV export. Requires Az.Accounts and Az.Network plus Reader on the target subscriptions. | 2026-08-30 |
