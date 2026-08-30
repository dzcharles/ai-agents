#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Network

<#
.SYNOPSIS
    Produces a read-only overview of Azure virtual networks across one or more subscriptions.

.DESCRIPTION
    Enumerates the virtual networks in the specified subscriptions (or in every enabled
    subscription visible to the signed-in account) and emits one object per virtual network
    describing its address space, subnets, DNS servers, peerings, DDoS protection state and tags.
    Objects are streamed to the pipeline as they are produced.

    With -IncludeSubnetDetail the function also emits one additional object per subnet, containing
    the subnet prefixes, the associated network security group and route table, service delegations,
    private endpoint / private link service network policies and the number of connected devices.

    The script never modifies an Azure resource. Errors that occur while processing a single
    subscription are reported as warnings and the run continues with the next subscription.
    The Az context that was active when the script started is restored before the script exits.

.PARAMETER SubscriptionId
    One or more subscription IDs to inspect. When omitted, all enabled subscriptions available to
    the current Az context are scanned.

.PARAMETER CsvPath
    Optional path to a CSV file. When supplied, all emitted objects are also exported to this file.
    Tags, peerings and other collection-like properties are flattened to strings for the export.

.PARAMETER IncludeSubnetDetail
    Emit an additional object for every subnet in each virtual network.

.EXAMPLE
    ./Get-AzVNetOverview.ps1 | Format-Table Subscription, VNetName, Location, AddressSpace, SubnetCount

    Lists the virtual networks in every enabled subscription and displays a summary table.

.EXAMPLE
    ./Get-AzVNetOverview.ps1 -SubscriptionId '00000000-0000-0000-0000-000000000000' -IncludeSubnetDetail -CsvPath ./vnets.csv

    Inspects a single subscription, includes per-subnet rows and writes everything to vnets.csv.

.EXAMPLE
    ./Get-AzVNetOverview.ps1 -Verbose | Where-Object { $_.PeeringCount -eq 0 }

    Finds virtual networks that have no peerings, with progress information written to the verbose stream.

.OUTPUTS
    System.Management.Automation.PSCustomObject

.NOTES
    Read-only. Requires the Reader role (or higher) on the subscriptions being inspected.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$SubscriptionId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$CsvPath,

    [Parameter()]
    [switch]$IncludeSubnetDetail
)

begin {
    Set-StrictMode -Version Latest

    function Get-CurrentAzContext {
        [CmdletBinding()]
        [OutputType([Microsoft.Azure.Commands.Profile.Models.Core.PSAzureContext])]
        param()

        try {
            $context = Get-AzContext -ErrorAction Stop
        }
        catch {
            $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new("Unable to read the current Az context: $($_.Exception.Message)", $_.Exception),
                'AzContextReadFailed',
                [System.Management.Automation.ErrorCategory]::ConnectionError,
                $null
            )
            $PSCmdlet.ThrowTerminatingError($errorRecord)
        }

        if (-not $context -or -not $context.Account) {
            $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new('No authenticated Azure context was found. Run Connect-AzAccount and try again.'),
                'AzContextNotFound',
                [System.Management.Automation.ErrorCategory]::AuthenticationError,
                $null
            )
            $PSCmdlet.ThrowTerminatingError($errorRecord)
        }

        return $context
    }

    function Get-TargetSubscription {
        [CmdletBinding()]
        [OutputType([object[]])]
        param(
            [string[]]$Id
        )

        if ($Id) {
            $subscriptions = foreach ($current in $Id) {
                try {
                    Get-AzSubscription -SubscriptionId $current -ErrorAction Stop
                }
                catch {
                    Write-Warning "Skipping subscription '$current': $($_.Exception.Message)"
                }
            }
        }
        else {
            try {
                $subscriptions = Get-AzSubscription -ErrorAction Stop |
                    Where-Object { $_.State -eq 'Enabled' }
            }
            catch {
                $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new("Unable to enumerate subscriptions: $($_.Exception.Message)", $_.Exception),
                    'SubscriptionEnumerationFailed',
                    [System.Management.Automation.ErrorCategory]::ResourceUnavailable,
                    $null
                )
                $PSCmdlet.ThrowTerminatingError($errorRecord)
            }
        }

        return @($subscriptions)
    }

    function ConvertTo-TagString {
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [System.Collections.IDictionary]$Tag
        )

        if (-not $Tag -or $Tag.Count -eq 0) { return '' }

        return (($Tag.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; ')
    }

    function Get-ResourceNameFromId {
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [string]$ResourceId
        )

        if ([string]::IsNullOrWhiteSpace($ResourceId)) { return '' }

        return ($ResourceId -split '/')[-1]
    }

    function ConvertTo-VNetSummary {
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory)]
            [object]$VirtualNetwork,

            [Parameter(Mandatory)]
            [string]$SubscriptionName
        )

        $peerings = @($VirtualNetwork.VirtualNetworkPeerings)
        $peeringText = if ($peerings.Count -gt 0) {
            ($peerings | ForEach-Object { "$($_.Name) -> $($_.PeeringState)" }) -join '; '
        }
        else { '' }

        $ddosEnabled = $false
        if ($VirtualNetwork.PSObject.Properties.Name -contains 'EnableDdosProtection') {
            $ddosEnabled = [bool]$VirtualNetwork.EnableDdosProtection
        }

        [pscustomobject]@{
            RowType               = 'VNet'
            Subscription          = $SubscriptionName
            ResourceGroup         = $VirtualNetwork.ResourceGroupName
            VNetName              = $VirtualNetwork.Name
            Location              = $VirtualNetwork.Location
            AddressSpace          = ($VirtualNetwork.AddressSpace.AddressPrefixes -join ', ')
            SubnetCount           = @($VirtualNetwork.Subnets).Count
            DnsServers            = ($VirtualNetwork.DhcpOptions.DnsServers -join ', ')
            PeeringCount          = $peerings.Count
            Peerings              = $peeringText
            DdosProtectionEnabled = $ddosEnabled
            Tags                  = ConvertTo-TagString -Tag $VirtualNetwork.Tag
            ResourceId            = $VirtualNetwork.Id
        }
    }

    function ConvertTo-SubnetDetail {
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory)]
            [object]$VirtualNetwork,

            [Parameter(Mandatory)]
            [object]$Subnet,

            [Parameter(Mandatory)]
            [string]$SubscriptionName
        )

        $prefixes = if ($Subnet.PSObject.Properties.Name -contains 'AddressPrefix' -and $Subnet.AddressPrefix) {
            @($Subnet.AddressPrefix) -join ', '
        }
        else { '' }

        $delegations = ''
        if ($Subnet.PSObject.Properties.Name -contains 'Delegations' -and $Subnet.Delegations) {
            $delegations = (@($Subnet.Delegations) | ForEach-Object { $_.ServiceName }) -join ', '
        }

        [pscustomobject]@{
            RowType                           = 'Subnet'
            Subscription                      = $SubscriptionName
            ResourceGroup                     = $VirtualNetwork.ResourceGroupName
            VNetName                          = $VirtualNetwork.Name
            Location                          = $VirtualNetwork.Location
            SubnetName                        = $Subnet.Name
            SubnetPrefix                      = $prefixes
            NetworkSecurityGroup              = Get-ResourceNameFromId -ResourceId $Subnet.NetworkSecurityGroup.Id
            RouteTable                        = Get-ResourceNameFromId -ResourceId $Subnet.RouteTable.Id
            Delegations                       = $delegations
            PrivateEndpointNetworkPolicies    = [string]$Subnet.PrivateEndpointNetworkPolicies
            PrivateLinkServiceNetworkPolicies = [string]$Subnet.PrivateLinkServiceNetworkPolicies
            ConnectedDeviceCount              = @($Subnet.IpConfigurations).Count
            ResourceId                        = $Subnet.Id
        }
    }

    $originalContext = Get-CurrentAzContext

    # Only buffered when -CsvPath is used; otherwise objects stream straight to the pipeline.
    $results = [System.Collections.Generic.List[pscustomobject]]::new()
}

process {
    try {
        $subscriptions = Get-TargetSubscription -Id $SubscriptionId

        if ($subscriptions.Count -eq 0) {
            Write-Warning 'No subscriptions were resolved. Nothing to inspect.'
            return
        }

        foreach ($subscription in $subscriptions) {
            Write-Verbose "Processing subscription '$($subscription.Name)' ($($subscription.Id))."

            try {
                $null = Set-AzContext -SubscriptionId $subscription.Id -ErrorAction Stop -WarningAction SilentlyContinue
                $vnets = @(Get-AzVirtualNetwork -ErrorAction Stop)
            }
            catch {
                Write-Warning "Skipping subscription '$($subscription.Name)' ($($subscription.Id)): $($_.Exception.Message)"
                continue
            }

            foreach ($vnet in $vnets) {
                try {
                    $vnetRow = ConvertTo-VNetSummary -VirtualNetwork $vnet -SubscriptionName $subscription.Name
                    if ($CsvPath) { $results.Add($vnetRow) }
                    Write-Output $vnetRow

                    if ($IncludeSubnetDetail.IsPresent) {
                        foreach ($subnet in @($vnet.Subnets)) {
                            $subnetRow = ConvertTo-SubnetDetail -VirtualNetwork $vnet -Subnet $subnet -SubscriptionName $subscription.Name
                            if ($CsvPath) { $results.Add($subnetRow) }
                            Write-Output $subnetRow
                        }
                    }
                }
                catch {
                    Write-Warning "Failed to process virtual network '$($vnet.Name)' in '$($subscription.Name)': $($_.Exception.Message)"
                }
            }
        }
    }
    finally {
        if ($originalContext -and $originalContext.Subscription) {
            try {
                $null = Set-AzContext -SubscriptionId $originalContext.Subscription.Id -ErrorAction Stop -WarningAction SilentlyContinue
            }
            catch {
                Write-Warning "Unable to restore the original Az context: $($_.Exception.Message)"
            }
        }
    }
}

end {
    if ($CsvPath) {
        try {
            $csvDirectory = Split-Path -Path $CsvPath -Parent
            if ($csvDirectory -and -not (Test-Path -LiteralPath $csvDirectory)) {
                $null = New-Item -Path $csvDirectory -ItemType Directory -Force -ErrorAction Stop
            }

            $results | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding utf8 -ErrorAction Stop
            Write-Verbose "Exported $($results.Count) row(s) to '$CsvPath'."
        }
        catch {
            Write-Warning "Failed to export results to '$CsvPath': $($_.Exception.Message)"
        }
    }
}
