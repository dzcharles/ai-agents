#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Groups, Microsoft.Graph.Identity.Governance

<#
.SYNOPSIS
    Onboards a Microsoft Entra ID group to Privileged Identity Management (PIM) for Groups, configures
    its activation policy and creates eligible assignments.

.DESCRIPTION
    Microsoft Entra ID groups cannot be explicitly "enabled" for PIM for Groups. A group is onboarded
    automatically the first time its role management policy is updated or the first time an eligibility
    or active assignment is created for it. This script performs both steps in one call:

    1. Updates the PIM activation policy (role management policy) for the Member and/or Owner role on
       the group: maximum activation duration, whether justification/MFA/ticket information are required
       to activate, whether approval is required (and who the approvers are), and the maximum duration
       a principal can be made eligible for.
    2. Optionally creates eligible assignments for one or more principals (users or groups) on the
       selected role(s), either permanent or expiring after a duration.

    PIM for Groups policy rules are only available on the Microsoft Graph beta endpoint, so policy
    updates are sent with Invoke-MgGraphRequest against /beta. Eligibility assignments use the v1.0
    Microsoft.Graph.Identity.Governance cmdlet.

    The script is destructive to the group's PIM configuration (it overwrites the targeted policy rules),
    so it supports -WhatIf/-Confirm and prompts before making changes.

.PARAMETER GroupId
    Object id (GUID) of the Microsoft Entra ID group to onboard. The group must not be a dynamic
    membership group or a group synchronized from on-premises Active Directory.

.PARAMETER Role
    The PIM role(s) on the group to configure: Member, Owner or both. Defaults to Member.

.PARAMETER MaxActivationDuration
    ISO 8601 duration string for the maximum time a principal can activate the role for, e.g. 'PT8H'.
    Defaults to 'PT8H' (8 hours).

.PARAMETER RequireJustificationOnActivation
    Requires a justification when a principal activates eligible membership/ownership.

.PARAMETER RequireMfaOnActivation
    Requires multi-factor authentication when a principal activates eligible membership/ownership.

.PARAMETER RequireTicketInfoOnActivation
    Requires ticket information (ticket number and system) when a principal activates.

.PARAMETER RequireApproval
    Requires approval to activate the role. -ApproverId must be supplied when this is set.

.PARAMETER ApproverId
    Object id(s) of the users to configure as primary approvers. Required when -RequireApproval is set.

.PARAMETER MaxEligibilityDuration
    ISO 8601 duration string for the maximum duration an eligible assignment can have, e.g. 'P180D'.
    When omitted, permanent eligibility remains allowed by the policy.

.PARAMETER EligiblePrincipalId
    Object id(s) of the users or groups to make eligible for the selected -Role(s) on the group.

.PARAMETER EligibilityDuration
    ISO 8601 duration string for the eligible assignments created via -EligiblePrincipalId, e.g. 'P90D'.
    When omitted, the eligible assignments are created as permanent (subject to -MaxEligibilityDuration).

.PARAMETER AssignmentJustification
    Justification recorded on the eligible assignment requests. Defaults to a generic automation message.

.PARAMETER PassThru
    Returns objects describing the policy rules updated and the eligibility requests created.

.PARAMETER LogPath
    Path of the log file. Defaults to a timestamped file in a 'logs' folder next to the script.

.EXAMPLE
    ./Enable-PimGroup.ps1 -GroupId '11111111-1111-1111-1111-111111111111' -Role Member `
        -MaxActivationDuration PT4H -RequireJustificationOnActivation -RequireMfaOnActivation

    Configures the Member activation policy on the group to a 4-hour maximum, requiring justification
    and MFA to activate. No eligible assignments are created.

.EXAMPLE
    ./Enable-PimGroup.ps1 -GroupId '11111111-1111-1111-1111-111111111111' -Role Member, Owner `
        -MaxActivationDuration PT8H -RequireMfaOnActivation -RequireApproval `
        -ApproverId '22222222-2222-2222-2222-222222222222' -MaxEligibilityDuration P180D `
        -EligiblePrincipalId '33333333-3333-3333-3333-333333333333' -EligibilityDuration P90D -WhatIf

    Shows what would change: configures both Member and Owner policies with approval required, and
    previews adding one principal as eligible for 90 days, without applying any changes.

.OUTPUTS
    System.Management.Automation.PSCustomObject
    Emitted only with -PassThru: one object per policy rule updated and one per eligibility request
    created, each with a Type, Role and Detail property.

.NOTES
    Author       : Personal assistant generated script
    Requires     : Microsoft.Graph.Authentication, Microsoft.Graph.Groups, Microsoft.Graph.Identity.Governance, PowerShell 7+
    Permissions  : Delegated Microsoft Graph scopes RoleManagementPolicy.ReadWrite.AzureADGroup,
                   PrivilegedEligibilitySchedule.ReadWrite.AzureADGroup and Group.Read.All. Requires an
                   Entra ID P2 (or EMS E5) license and a role such as Privileged Role Administrator or
                   Group owner with PIM permissions.
    Limitations  : Approvers are configured as individual users only (no group approvers). Active
                   (non-eligible) assignments are not created by this script, only eligible assignments.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$GroupId,

    [Parameter()]
    [ValidateSet('Member', 'Owner')]
    [string[]]$Role = @('Member'),

    [Parameter()]
    [ValidatePattern('^P(?!$)(\d+Y)?(\d+M)?(\d+D)?(T(?=\d)(\d+H)?(\d+M)?(\d+S)?)?$')]
    [string]$MaxActivationDuration = 'PT8H',

    [Parameter()]
    [switch]$RequireJustificationOnActivation,

    [Parameter()]
    [switch]$RequireMfaOnActivation,

    [Parameter()]
    [switch]$RequireTicketInfoOnActivation,

    [Parameter()]
    [switch]$RequireApproval,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$ApproverId,

    [Parameter()]
    [ValidatePattern('^P(?!$)(\d+Y)?(\d+M)?(\d+D)?(T(?=\d)(\d+H)?(\d+M)?(\d+S)?)?$')]
    [string]$MaxEligibilityDuration,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$EligiblePrincipalId,

    [Parameter()]
    [ValidatePattern('^P(?!$)(\d+Y)?(\d+M)?(\d+D)?(T(?=\d)(\d+H)?(\d+M)?(\d+S)?)?$')]
    [string]$EligibilityDuration,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$AssignmentJustification = 'Onboarded to PIM for Groups via automation script.',

    [Parameter()]
    [switch]$PassThru,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogPath = (Join-Path -Path $PSScriptRoot -ChildPath ('logs/Enable-PimGroup_{0:yyyyMMdd-HHmmss}.log' -f (Get-Date)))
)

begin {
    $ErrorActionPreference = 'Stop'

    function Write-ScriptLog {
        <#
        .SYNOPSIS
            Writes a timestamped message to the log file and to the matching PowerShell stream.
        .PARAMETER Message
            The message to log.
        .PARAMETER Level
            Severity of the message: Info, Warning or Error.
        .PARAMETER Path
            Path of the log file.
        .OUTPUTS
            None.
        #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [ValidateNotNullOrEmpty()]
            [string]$Message,

            [Parameter()]
            [ValidateSet('Info', 'Warning', 'Error')]
            [string]$Level = 'Info',

            [Parameter(Mandatory)]
            [ValidateNotNullOrEmpty()]
            [string]$Path
        )

        process {
            $logLine = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
            Add-Content -Path $Path -Value $logLine

            switch ($Level) {
                'Warning' { Write-Warning -Message $Message }
                'Error' { Write-Error -Message $Message }
                default { Write-Verbose -Message $Message }
            }
        }
    }

    function Set-PimGroupPolicyRule {
        <#
        .SYNOPSIS
            Updates a single PIM for Groups policy rule using the Microsoft Graph beta endpoint.
        .PARAMETER PolicyId
            Id of the unifiedRoleManagementPolicy that owns the rule.
        .PARAMETER RuleId
            Id of the rule to update, e.g. 'Expiration_EndUser_Assignment'.
        .PARAMETER Body
            Hashtable representing the updated rule, including '@odata.type' and 'id'.
        .OUTPUTS
            None.
        #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [ValidateNotNullOrEmpty()]
            [string]$PolicyId,

            [Parameter(Mandatory)]
            [ValidateNotNullOrEmpty()]
            [string]$RuleId,

            [Parameter(Mandatory)]
            [hashtable]$Body
        )

        process {
            $uri = "https://graph.microsoft.com/beta/policies/roleManagementPolicies/$PolicyId/rules/$RuleId"
            Invoke-MgGraphRequest -Method PATCH -Uri $uri -Body ($Body | ConvertTo-Json -Depth 10) -ContentType 'application/json' | Out-Null
        }
    }

    $logDirectory = Split-Path -Path $LogPath -Parent
    if (-not (Test-Path -Path $logDirectory)) {
        New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
    }

    if ($RequireApproval.IsPresent -and -not $ApproverId) {
        throw '-ApproverId is required when -RequireApproval is specified.'
    }

    $requiredScopes = @(
        'RoleManagementPolicy.ReadWrite.AzureADGroup',
        'PrivilegedEligibilitySchedule.ReadWrite.AzureADGroup',
        'Group.Read.All'
    )

    $context = Get-MgContext
    if (-not $context -or (Compare-Object -ReferenceObject $requiredScopes -DifferenceObject $context.Scopes | Where-Object { $_.SideIndicator -eq '<=' })) {
        Write-ScriptLog -Message 'Connecting to Microsoft Graph via browser sign-in.' -Path $LogPath
        Connect-MgGraph -Scopes $requiredScopes -NoWelcome
    }

    Write-ScriptLog -Message "Validating group '$GroupId'." -Path $LogPath
    $group = Get-MgGroup -GroupId $GroupId -Property Id, DisplayName, GroupTypes, OnPremisesSyncEnabled, SecurityEnabled, MailEnabled

    if ($group.OnPremisesSyncEnabled) {
        throw "Group '$GroupId' is synchronized from on-premises Active Directory and cannot be used with PIM for Groups."
    }
    if ($group.GroupTypes -contains 'DynamicMembership') {
        throw "Group '$GroupId' has dynamic membership and cannot be used with PIM for Groups."
    }

    Write-ScriptLog -Message "Onboarding group '$($group.DisplayName)' ($GroupId) to PIM for Groups." -Path $LogPath
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
}

process {
    foreach ($currentRole in $Role) {
        $roleDefinitionId = $currentRole.ToLowerInvariant()

        $assignmentFilter = "scopeId eq '$GroupId' and scopeType eq 'Group' and roleDefinitionId eq '$roleDefinitionId'"
        $assignmentUri = "https://graph.microsoft.com/beta/policies/roleManagementPolicyAssignments?`$filter=$assignmentFilter"
        $policyAssignment = (Invoke-MgGraphRequest -Method GET -Uri $assignmentUri).value | Select-Object -First 1

        if (-not $policyAssignment) {
            Write-ScriptLog -Message "No PIM policy assignment found for role '$currentRole' on group '$GroupId'." -Level Error -Path $LogPath
            continue
        }
        $policyId = $policyAssignment.policyId

        $expirationRule = @{
            '@odata.type'       = '#microsoft.graph.unifiedRoleManagementPolicyExpirationRule'
            id                  = 'Expiration_EndUser_Assignment'
            isExpirationRequired = $true
            maximumDuration     = $MaxActivationDuration
        }
        if ($PSCmdlet.ShouldProcess("Group $GroupId ($currentRole)", "Set maximum activation duration to $MaxActivationDuration")) {
            Set-PimGroupPolicyRule -PolicyId $policyId -RuleId 'Expiration_EndUser_Assignment' -Body $expirationRule
            Write-ScriptLog -Message "Set max activation duration for $currentRole to $MaxActivationDuration." -Path $LogPath
            $results.Add([PSCustomObject]@{ Type = 'Policy'; Role = $currentRole; Detail = "MaxActivationDuration=$MaxActivationDuration" })
        }

        $enabledRules = [System.Collections.Generic.List[string]]::new()
        if ($RequireJustificationOnActivation.IsPresent) { $enabledRules.Add('Justification') }
        if ($RequireMfaOnActivation.IsPresent) { $enabledRules.Add('MultiFactorAuthentication') }
        if ($RequireTicketInfoOnActivation.IsPresent) { $enabledRules.Add('Ticketing') }

        $enablementRule = @{
            '@odata.type' = '#microsoft.graph.unifiedRoleManagementPolicyEnablementRule'
            id            = 'Enablement_EndUser_Assignment'
            enabledRules  = @($enabledRules)
        }
        if ($PSCmdlet.ShouldProcess("Group $GroupId ($currentRole)", "Set activation requirements to [$($enabledRules -join ', ')]")) {
            Set-PimGroupPolicyRule -PolicyId $policyId -RuleId 'Enablement_EndUser_Assignment' -Body $enablementRule
            Write-ScriptLog -Message "Set activation requirements for $currentRole to [$($enabledRules -join ', ')]." -Path $LogPath
            $results.Add([PSCustomObject]@{ Type = 'Policy'; Role = $currentRole; Detail = "ActivationRequirements=$($enabledRules -join ', ')" })
        }

        $approvalStages = @()
        if ($RequireApproval.IsPresent) {
            $approvalStages = @(
                @{
                    approvalStageTimeOutInDays      = 1
                    isApproverJustificationRequired  = $true
                    escalationTimeInMinutes          = 0
                    isEscalationEnabled              = $false
                    escalationApprovers              = @()
                    primaryApprovers                 = @($ApproverId | ForEach-Object {
                            @{ '@odata.type' = '#microsoft.graph.singleUser'; userId = $_ }
                        })
                }
            )
        }
        $approvalRule = @{
            '@odata.type' = '#microsoft.graph.unifiedRoleManagementPolicyApprovalRule'
            id            = 'Approval_EndUser_Assignment'
            setting       = @{
                isApprovalRequired = $RequireApproval.IsPresent
                approvalStages     = $approvalStages
            }
        }
        if ($PSCmdlet.ShouldProcess("Group $GroupId ($currentRole)", "Set require approval to $($RequireApproval.IsPresent)")) {
            Set-PimGroupPolicyRule -PolicyId $policyId -RuleId 'Approval_EndUser_Assignment' -Body $approvalRule
            Write-ScriptLog -Message "Set require approval for $currentRole to $($RequireApproval.IsPresent)." -Path $LogPath
            $results.Add([PSCustomObject]@{ Type = 'Policy'; Role = $currentRole; Detail = "RequireApproval=$($RequireApproval.IsPresent)" })
        }

        if ($MaxEligibilityDuration) {
            $eligibilityExpirationRule = @{
                '@odata.type'       = '#microsoft.graph.unifiedRoleManagementPolicyExpirationRule'
                id                  = 'Expiration_Admin_Eligibility'
                isExpirationRequired = $true
                maximumDuration     = $MaxEligibilityDuration
            }
            if ($PSCmdlet.ShouldProcess("Group $GroupId ($currentRole)", "Set maximum eligibility duration to $MaxEligibilityDuration")) {
                Set-PimGroupPolicyRule -PolicyId $policyId -RuleId 'Expiration_Admin_Eligibility' -Body $eligibilityExpirationRule
                Write-ScriptLog -Message "Set max eligibility duration for $currentRole to $MaxEligibilityDuration." -Path $LogPath
                $results.Add([PSCustomObject]@{ Type = 'Policy'; Role = $currentRole; Detail = "MaxEligibilityDuration=$MaxEligibilityDuration" })
            }
        }

        foreach ($principalId in $EligiblePrincipalId) {
            $scheduleInfo = @{
                startDateTime = (Get-Date).ToUniversalTime()
                expiration    = if ($EligibilityDuration) {
                    @{ type = 'AfterDuration'; duration = $EligibilityDuration }
                }
                else {
                    @{ type = 'NoExpiration' }
                }
            }

            if ($PSCmdlet.ShouldProcess("Principal $principalId", "Create eligible $currentRole assignment on group $GroupId")) {
                $request = New-MgIdentityGovernancePrivilegedAccessGroupEligibilityScheduleRequest -GroupId $GroupId `
                    -AccessId $roleDefinitionId -PrincipalId $principalId -Action AdminAssign `
                    -ScheduleInfo $scheduleInfo -Justification $AssignmentJustification

                Write-ScriptLog -Message "Created eligible $currentRole assignment for principal '$principalId' on group '$GroupId'." -Path $LogPath
                $results.Add([PSCustomObject]@{ Type = 'Eligibility'; Role = $currentRole; Detail = "PrincipalId=$principalId; RequestId=$($request.Id)" })
            }
        }
    }
}

end {
    Write-ScriptLog -Message "Completed PIM for Groups configuration for group '$GroupId'." -Path $LogPath

    if ($PassThru.IsPresent) {
        Write-Output $results
    }
}
