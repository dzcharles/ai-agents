# Scripts index

Reusable automation scripts in this repository.

| script | type | title | description | last updated |
| --- | --- | --- | --- | --- |
| [Test-NsgIpAccess.ps1](Test-NsgIpAccess.ps1) | PowerShell | Azure NSG IP access evaluator | Evaluates whether an IPv4/IPv6 address is allowed or denied by Azure Network Security Group rules, applying priority-ordered first-match semantics across custom and default rules, with CIDR, port range, protocol and service tag handling. | 2026-08-31 |
| [Enable-PimGroup.ps1](Enable-PimGroup.ps1) | PowerShell | Entra ID PIM for Groups onboarding | Onboards a Microsoft Entra ID group to Privileged Identity Management for Groups via Microsoft Graph: configures activation policy (max activation duration, justification/MFA/ticket requirements, approval and approvers, max eligibility duration) for Member and/or Owner, and creates eligible assignments for principals. | 2026-08-31 |
| [Get-AzureSqlPerformanceBenchmark.ps1](Get-AzureSqlPerformanceBenchmark.ps1) | PowerShell | Azure SQL Database performance benchmark | Collects a bounded, read-only Entra-authenticated Azure SQL Database performance snapshot before or after an index change, exporting index, Query Store, resource, allocated-file-size, and optional cumulative wait statistics. | 2026-09-04 |
