#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Network

<#
.SYNOPSIS
    Tests whether an IP address is allowed or denied by Azure Network Security Group (NSG) rules.

.DESCRIPTION
    Retrieves the Network Security Groups in scope and evaluates both the custom security rules
    and the default security rules against a supplied IP address, optional destination port and
    optional protocol.

    Azure NSG semantics are applied: rules are evaluated in ascending priority order and the first
    rule that matches wins, whether it is an Allow or a Deny rule. For inbound evaluation the source
    address fields are matched, for outbound evaluation the destination address fields are matched.

    Address matching supports single IP addresses, CIDR notation (bitwise comparison on the 32-bit
    integer for IPv4, byte-wise prefix comparison for IPv6), the multi-value SourceAddressPrefixes /
    DestinationAddressPrefixes arrays and the wildcard values '*' and 'Any'. Named service tags
    (Internet, VirtualNetwork, AzureLoadBalancer, Storage, ...) cannot be resolved to address ranges
    from the rule definition alone, so a rule that would otherwise match on a service tag is reported
    as 'Indeterminate' instead of being guessed.

    The script is read-only: it never modifies Azure resources. Progress, warnings and errors are
    written to a log file and to the appropriate PowerShell streams.

.PARAMETER IpAddress
    The IPv4 or IPv6 address to test against the NSG rules. Mandatory.

.PARAMETER SubscriptionId
    Optional subscription id. When supplied the Azure context is switched to this subscription
    before the NSGs are retrieved. When omitted the current context is used.

.PARAMETER ResourceGroupName
    Optional resource group name used to scope the NSG lookup to a single resource group.

.PARAMETER NetworkSecurityGroupName
    Optional NSG name. When supplied only that NSG is evaluated. Requires ResourceGroupName when the
    same NSG name exists in multiple resource groups; otherwise the NSGs in scope are filtered by name.

.PARAMETER Direction
    Traffic direction to evaluate: Inbound, Outbound or Both. Defaults to Both.

.PARAMETER Port
    Optional destination port to evaluate. When omitted the rules are evaluated regardless of port and
    the port ranges of the matching rule are reported.

.PARAMETER Protocol
    Protocol to evaluate: Tcp, Udp, Icmp or Any. Defaults to Any, which matches every rule protocol.

.PARAMETER LogPath
    Path of the log file. Defaults to a timestamped file in a 'logs' folder next to the script.

.EXAMPLE
    ./Test-NsgIpAccess.ps1 -IpAddress 10.0.1.5

    Evaluates every NSG in the current subscription context for inbound and outbound access of
    10.0.1.5, for any protocol and any port.

.EXAMPLE
    ./Test-NsgIpAccess.ps1 -IpAddress 203.0.113.10 -Port 443 -Protocol Tcp -Direction Inbound -Verbose

    Evaluates inbound TCP access on port 443 from 203.0.113.10 and shows the per-rule diagnostics.

.EXAMPLE
    ./Test-NsgIpAccess.ps1 -IpAddress 10.0.1.5 -ResourceGroupName 'rg-network' -NetworkSecurityGroupName 'nsg-app' |
        Format-Table NsgName, Direction, Access, MatchedRuleName, Priority, MatchedPrefix

    Evaluates one specific NSG and formats the structured result.

.EXAMPLE
    ./Test-NsgIpAccess.ps1 -IpAddress 2001:db8::1 -SubscriptionId '00000000-0000-0000-0000-000000000000' |
        Where-Object { $_.Access -ne 'Allow' }

    Switches subscription, evaluates an IPv6 address and returns only the results that are not an Allow.

.OUTPUTS
    System.Management.Automation.PSCustomObject
    One object per evaluated NSG and direction with the properties NsgName, ResourceGroupName,
    Location, Direction, IpAddress, Port, Protocol, Access, MatchedRuleName, Priority, RuleType,
    MatchedPrefix, RuleProtocol, PortRange and Notes.

.NOTES
    Author      : Personal assistant generated script
    Requires    : Az.Accounts, Az.Network, PowerShell 7+
    Limitations : Service tags and Application Security Groups are not resolved; results that depend
                  on them are reported as 'Indeterminate'. NSG rules do not support IP ranges, so only
                  single addresses, CIDR prefixes, wildcards and service tags are handled.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({
            $parsed = [System.Net.IPAddress]::Any
            if (-not [System.Net.IPAddress]::TryParse($_, [ref]$parsed)) {
                throw "'$_' is not a valid IPv4 or IPv6 address."
            }
            $true
        })]
    [string]$IpAddress,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$NetworkSecurityGroupName,

    [Parameter()]
    [ValidateSet('Inbound', 'Outbound', 'Both')]
    [string]$Direction = 'Both',

    [Parameter()]
    [ValidateRange(1, 65535)]
    [int]$Port,

    [Parameter()]
    [ValidateSet('Tcp', 'Udp', 'Icmp', 'Any')]
    [string]$Protocol = 'Any',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogPath = (Join-Path -Path $PSScriptRoot -ChildPath ('logs/Test-NsgIpAccess_{0:yyyyMMdd-HHmmss}.log' -f (Get-Date)))
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

        $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level.ToUpperInvariant(), $Message

        try {
            Add-Content -Path $Path -Value $line -Encoding utf8 -ErrorAction Stop
        } catch {
            Write-Warning "Unable to write to log file '$Path': $($_.Exception.Message)"
        }

        switch ($Level) {
            'Warning' { Write-Warning -Message $Message }
            'Error' { Write-Error -Message $Message -ErrorAction Continue }
            default { Write-Verbose -Message $Message }
        }
    }

    function Test-IpAddressInPrefix {
        <#
        .SYNOPSIS
            Determines whether an IP address is contained in an NSG address prefix.
        .DESCRIPTION
            Supports the wildcards '*' and 'Any', single IP addresses and CIDR prefixes. IPv4 CIDR
            containment uses bitwise comparison on the 32-bit integer representation, IPv6 uses a
            byte-wise prefix comparison. Values that are neither an address nor a CIDR prefix are
            treated as service tags and reported as 'Indeterminate'.
        .PARAMETER Address
            The IP address to test.
        .PARAMETER Prefix
            The NSG address prefix, CIDR block, wildcard or service tag.
        .OUTPUTS
            System.String. One of 'Match', 'NoMatch' or 'Indeterminate'.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter(Mandatory)]
            [System.Net.IPAddress]$Address,

            [Parameter(Mandatory)]
            [AllowEmptyString()]
            [string]$Prefix
        )

        if ([string]::IsNullOrWhiteSpace($Prefix)) {
            return 'NoMatch'
        }

        $trimmed = $Prefix.Trim()

        if ($trimmed -eq '*' -or $trimmed -eq '0.0.0.0/0' -or $trimmed -eq '::/0' -or $trimmed -eq 'Any') {
            return 'Match'
        }

        $candidate = [System.Net.IPAddress]::Any
        if ([System.Net.IPAddress]::TryParse($trimmed, [ref]$candidate)) {
            if ($candidate.AddressFamily -ne $Address.AddressFamily) {
                return 'NoMatch'
            }
            if ($candidate.Equals($Address)) {
                return 'Match'
            }
            return 'NoMatch'
        }

        if ($trimmed -match '^(?<network>[^/]+)/(?<length>\d{1,3})$') {
            $network = [System.Net.IPAddress]::Any
            if (-not [System.Net.IPAddress]::TryParse($Matches['network'], [ref]$network)) {
                return 'Indeterminate'
            }

            $prefixLength = [int]$Matches['length']

            if ($network.AddressFamily -ne $Address.AddressFamily) {
                return 'NoMatch'
            }

            if ($network.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                if ($prefixLength -lt 0 -or $prefixLength -gt 32) {
                    return 'Indeterminate'
                }

                $networkValue = Convert-IPv4ToUInt32 -Address $network
                $addressValue = Convert-IPv4ToUInt32 -Address $Address

                if ($prefixLength -eq 0) {
                    return 'Match'
                }

                # 4294967295 is written in decimal because PowerShell parses 0xFFFFFFFF as [int] -1.
                $mask = [uint32]((([uint64]4294967295) -shl (32 - $prefixLength)) -band [uint64]4294967295)

                if (($networkValue -band $mask) -eq ($addressValue -band $mask)) {
                    return 'Match'
                }
                return 'NoMatch'
            }

            if ($prefixLength -lt 0 -or $prefixLength -gt 128) {
                return 'Indeterminate'
            }

            $networkBytes = $network.GetAddressBytes()
            $addressBytes = $Address.GetAddressBytes()
            $fullBytes = [math]::Floor($prefixLength / 8)
            $remainingBits = $prefixLength % 8

            for ($i = 0; $i -lt $fullBytes; $i++) {
                if ($networkBytes[$i] -ne $addressBytes[$i]) {
                    return 'NoMatch'
                }
            }

            if ($remainingBits -gt 0) {
                $partialMask = [byte](0xFF -shl (8 - $remainingBits) -band 0xFF)
                if (($networkBytes[$fullBytes] -band $partialMask) -ne ($addressBytes[$fullBytes] -band $partialMask)) {
                    return 'NoMatch'
                }
            }

            return 'Match'
        }

        # Anything else is a named service tag such as Internet, VirtualNetwork or AzureLoadBalancer.
        return 'Indeterminate'
    }

    function Convert-IPv4ToUInt32 {
        <#
        .SYNOPSIS
            Converts an IPv4 address to its 32-bit unsigned integer representation.
        .PARAMETER Address
            The IPv4 address to convert.
        .OUTPUTS
            System.UInt32
        #>
        [CmdletBinding()]
        [OutputType([uint32])]
        param(
            [Parameter(Mandatory)]
            [System.Net.IPAddress]$Address
        )

        $bytes = $Address.GetAddressBytes()
        return [uint32]((([uint32]$bytes[0]) -shl 24) -bor
            (([uint32]$bytes[1]) -shl 16) -bor
            (([uint32]$bytes[2]) -shl 8) -bor
            ([uint32]$bytes[3]))
    }

    function Test-PortInRange {
        <#
        .SYNOPSIS
            Determines whether a port is contained in an NSG port range expression.
        .PARAMETER PortNumber
            The port to test.
        .PARAMETER Range
            A port range expression: '*', a single port such as '443' or a range such as '80-443'.
        .OUTPUTS
            System.Boolean
        #>
        [CmdletBinding()]
        [OutputType([bool])]
        param(
            [Parameter(Mandatory)]
            [int]$PortNumber,

            [Parameter(Mandatory)]
            [AllowEmptyString()]
            [string]$Range
        )

        if ([string]::IsNullOrWhiteSpace($Range)) {
            return $false
        }

        $trimmed = $Range.Trim()

        if ($trimmed -eq '*' -or $trimmed -eq '0-65535') {
            return $true
        }

        if ($trimmed -match '^(?<start>\d{1,5})-(?<end>\d{1,5})$') {
            return ($PortNumber -ge [int]$Matches['start'] -and $PortNumber -le [int]$Matches['end'])
        }

        if ($trimmed -match '^\d{1,5}$') {
            return ($PortNumber -eq [int]$trimmed)
        }

        return $false
    }

    function Get-RuleAddressPrefix {
        <#
        .SYNOPSIS
            Returns the address prefixes of a security rule for the requested direction.
        .PARAMETER Rule
            The NSG security rule object.
        .PARAMETER TrafficDirection
            'Inbound' to read the source address fields, 'Outbound' for the destination fields.
        .OUTPUTS
            System.String[]
        #>
        [CmdletBinding()]
        [OutputType([string[]])]
        param(
            [Parameter(Mandatory)]
            [object]$Rule,

            [Parameter(Mandatory)]
            [ValidateSet('Inbound', 'Outbound')]
            [string]$TrafficDirection
        )

        $prefixes = [System.Collections.Generic.List[string]]::new()

        if ($TrafficDirection -eq 'Inbound') {
            $single = $Rule.SourceAddressPrefix
            $multiple = $Rule.SourceAddressPrefixes
        } else {
            $single = $Rule.DestinationAddressPrefix
            $multiple = $Rule.DestinationAddressPrefixes
        }

        if (-not [string]::IsNullOrWhiteSpace($single)) {
            $prefixes.Add($single)
        }

        foreach ($value in @($multiple)) {
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $prefixes.Add($value)
            }
        }

        return $prefixes.ToArray()
    }

    function Get-RulePortRange {
        <#
        .SYNOPSIS
            Returns the destination port ranges of a security rule.
        .PARAMETER Rule
            The NSG security rule object.
        .OUTPUTS
            System.String[]
        #>
        [CmdletBinding()]
        [OutputType([string[]])]
        param(
            [Parameter(Mandatory)]
            [object]$Rule
        )

        $ranges = [System.Collections.Generic.List[string]]::new()

        if (-not [string]::IsNullOrWhiteSpace($Rule.DestinationPortRange)) {
            $ranges.Add($Rule.DestinationPortRange)
        }

        foreach ($value in @($Rule.DestinationPortRanges)) {
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $ranges.Add($value)
            }
        }

        return $ranges.ToArray()
    }

    function Test-RuleProtocol {
        <#
        .SYNOPSIS
            Determines whether the requested protocol matches the rule protocol.
        .PARAMETER RuleProtocol
            Protocol of the security rule, for example 'Tcp', 'Udp', 'Icmp' or '*'.
        .PARAMETER RequestedProtocol
            Protocol requested by the caller, or 'Any' to match every rule protocol.
        .OUTPUTS
            System.Boolean
        #>
        [CmdletBinding()]
        [OutputType([bool])]
        param(
            [Parameter(Mandatory)]
            [AllowEmptyString()]
            [string]$RuleProtocol,

            [Parameter(Mandatory)]
            [string]$RequestedProtocol
        )

        if ($RequestedProtocol -eq 'Any') {
            return $true
        }

        if ([string]::IsNullOrWhiteSpace($RuleProtocol) -or $RuleProtocol -eq '*') {
            return $true
        }

        return ($RuleProtocol -eq $RequestedProtocol)
    }

    $logDirectory = Split-Path -Path $LogPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($logDirectory) -and -not (Test-Path -Path $logDirectory)) {
        $null = New-Item -Path $logDirectory -ItemType Directory -Force
    }

    Write-ScriptLog -Message "Starting NSG evaluation for IP '$IpAddress' (Direction: $Direction, Protocol: $Protocol, Port: $(if ($PSBoundParameters.ContainsKey('Port')) { $Port } else { 'Any' }))." -Path $LogPath

    try {
        $context = Get-AzContext -ErrorAction Stop
    } catch {
        $context = $null
    }

    if (-not $context -or -not $context.Account) {
        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new('No active Azure session found. Run Connect-AzAccount before executing this script.'),
            'NoAzureSession',
            [System.Management.Automation.ErrorCategory]::AuthenticationError,
            $null
        )
        Write-ScriptLog -Message 'No active Azure session found.' -Level 'Error' -Path $LogPath
        $PSCmdlet.ThrowTerminatingError($errorRecord)
    }

    if ($PSBoundParameters.ContainsKey('SubscriptionId') -and $context.Subscription.Id -ne $SubscriptionId) {
        try {
            $context = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
            Write-ScriptLog -Message "Azure context set to subscription '$SubscriptionId'." -Path $LogPath
        } catch {
            $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                $_.Exception,
                'SetContextFailed',
                [System.Management.Automation.ErrorCategory]::InvalidOperation,
                $SubscriptionId
            )
            Write-ScriptLog -Message "Unable to set the Azure context to subscription '$SubscriptionId': $($_.Exception.Message)" -Level 'Error' -Path $LogPath
            $PSCmdlet.ThrowTerminatingError($errorRecord)
        }
    }

    $targetAddress = [System.Net.IPAddress]::Parse($IpAddress)
    $directionsToEvaluate = if ($Direction -eq 'Both') { @('Inbound', 'Outbound') } else { @($Direction) }
}

process {
    try {
        $getParameters = @{ ErrorAction = 'Stop' }
        if ($PSBoundParameters.ContainsKey('ResourceGroupName')) {
            $getParameters['ResourceGroupName'] = $ResourceGroupName
        }
        if ($PSBoundParameters.ContainsKey('NetworkSecurityGroupName') -and $PSBoundParameters.ContainsKey('ResourceGroupName')) {
            $getParameters['Name'] = $NetworkSecurityGroupName
        }

        $networkSecurityGroups = @(Get-AzNetworkSecurityGroup @getParameters)

        if ($PSBoundParameters.ContainsKey('NetworkSecurityGroupName') -and -not $getParameters.ContainsKey('Name')) {
            $networkSecurityGroups = @($networkSecurityGroups | Where-Object { $_.Name -eq $NetworkSecurityGroupName })
        }
    } catch {
        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            $_.Exception,
            'NsgRetrievalFailed',
            [System.Management.Automation.ErrorCategory]::ObjectNotFound,
            $NetworkSecurityGroupName
        )
        Write-ScriptLog -Message "Unable to retrieve network security groups: $($_.Exception.Message)" -Level 'Error' -Path $LogPath
        $PSCmdlet.ThrowTerminatingError($errorRecord)
    }

    if ($networkSecurityGroups.Count -eq 0) {
        Write-ScriptLog -Message 'No network security groups were found for the requested scope.' -Level 'Warning' -Path $LogPath
        return
    }

    Write-ScriptLog -Message "Evaluating $($networkSecurityGroups.Count) network security group(s)." -Path $LogPath

    foreach ($nsg in $networkSecurityGroups) {
        $allRules = @()
        $allRules += @($nsg.SecurityRules | ForEach-Object {
                [PSCustomObject]@{ Rule = $_; RuleType = 'Custom' }
            })
        $allRules += @($nsg.DefaultSecurityRules | ForEach-Object {
                [PSCustomObject]@{ Rule = $_; RuleType = 'Default' }
            })

        foreach ($currentDirection in $directionsToEvaluate) {
            $candidateRules = @($allRules |
                    Where-Object { $_.Rule.Direction -eq $currentDirection } |
                    Sort-Object -Property @{ Expression = { [int]$_.Rule.Priority } })

            $result = $null
            $notes = [System.Collections.Generic.List[string]]::new()

            foreach ($entry in $candidateRules) {
                $rule = $entry.Rule

                if (-not (Test-RuleProtocol -RuleProtocol ([string]$rule.Protocol) -RequestedProtocol $Protocol)) {
                    Write-Verbose "Rule '$($rule.Name)' skipped: protocol '$($rule.Protocol)' does not match '$Protocol'."
                    continue
                }

                $portRanges = Get-RulePortRange -Rule $rule
                $portRangeText = if ($portRanges.Count -gt 0) { $portRanges -join ',' } else { '*' }

                if ($PSBoundParameters.ContainsKey('Port')) {
                    $portMatched = $false
                    foreach ($range in $portRanges) {
                        if (Test-PortInRange -PortNumber $Port -Range $range) {
                            $portMatched = $true
                            break
                        }
                    }
                    if (-not $portMatched) {
                        Write-Verbose "Rule '$($rule.Name)' skipped: port $Port not in '$portRangeText'."
                        continue
                    }
                }

                $prefixes = Get-RuleAddressPrefix -Rule $rule -TrafficDirection $currentDirection

                $hasApplicationSecurityGroup = $false
                if ($currentDirection -eq 'Inbound') {
                    $hasApplicationSecurityGroup = @($rule.SourceApplicationSecurityGroups).Count -gt 0
                } else {
                    $hasApplicationSecurityGroup = @($rule.DestinationApplicationSecurityGroups).Count -gt 0
                }

                if ($prefixes.Count -eq 0 -and $hasApplicationSecurityGroup) {
                    $result = [PSCustomObject]@{
                        Access        = 'Indeterminate'
                        Rule          = $rule
                        RuleType      = $entry.RuleType
                        MatchedPrefix = 'ApplicationSecurityGroup'
                        PortRange     = $portRangeText
                    }
                    $notes.Add("Rule '$($rule.Name)' targets an Application Security Group; membership cannot be resolved from the rule definition.")
                    break
                }

                $matchState = 'NoMatch'
                $matchedPrefix = $null

                foreach ($prefix in $prefixes) {
                    $state = Test-IpAddressInPrefix -Address $targetAddress -Prefix $prefix
                    if ($state -eq 'Match') {
                        $matchState = 'Match'
                        $matchedPrefix = $prefix
                        break
                    }
                    if ($state -eq 'Indeterminate' -and $matchState -ne 'Match') {
                        $matchState = 'Indeterminate'
                        $matchedPrefix = $prefix
                    }
                }

                if ($matchState -eq 'NoMatch') {
                    Write-Verbose "Rule '$($rule.Name)' skipped: address '$IpAddress' not in '$($prefixes -join ',')'."
                    continue
                }

                if ($matchState -eq 'Indeterminate') {
                    $result = [PSCustomObject]@{
                        Access        = 'Indeterminate'
                        Rule          = $rule
                        RuleType      = $entry.RuleType
                        MatchedPrefix = $matchedPrefix
                        PortRange     = $portRangeText
                    }
                    $notes.Add("Indeterminate (service tag): rule '$($rule.Name)' uses service tag '$matchedPrefix'. If the IP belongs to that tag the effective access is '$($rule.Access)'; otherwise evaluation continues with lower priority rules.")
                    Write-ScriptLog -Message "NSG '$($nsg.Name)' $currentDirection : indeterminate match on service tag '$matchedPrefix' in rule '$($rule.Name)'." -Level 'Warning' -Path $LogPath
                    break
                }

                $result = [PSCustomObject]@{
                    Access        = [string]$rule.Access
                    Rule          = $rule
                    RuleType      = $entry.RuleType
                    MatchedPrefix = $matchedPrefix
                    PortRange     = $portRangeText
                }
                break
            }

            if (-not $PSBoundParameters.ContainsKey('Port')) {
                $notes.Add('No port filter applied; the reported port range is the range of the first matching rule.')
            }

            if ($null -eq $result) {
                $notes.Add('No rule matched. Azure denies traffic that does not match any rule.')

                [PSCustomObject]@{
                    NsgName           = $nsg.Name
                    ResourceGroupName = $nsg.ResourceGroupName
                    Location          = $nsg.Location
                    Direction         = $currentDirection
                    IpAddress         = $IpAddress
                    Port              = if ($PSBoundParameters.ContainsKey('Port')) { $Port } else { 'Any' }
                    Protocol          = $Protocol
                    Access            = 'Deny'
                    MatchedRuleName   = $null
                    Priority          = $null
                    RuleType          = $null
                    MatchedPrefix     = $null
                    RuleProtocol      = $null
                    PortRange         = $null
                    Notes             = ($notes -join ' ')
                }

                continue
            }

            [PSCustomObject]@{
                NsgName           = $nsg.Name
                ResourceGroupName = $nsg.ResourceGroupName
                Location          = $nsg.Location
                Direction         = $currentDirection
                IpAddress         = $IpAddress
                Port              = if ($PSBoundParameters.ContainsKey('Port')) { $Port } else { 'Any' }
                Protocol          = $Protocol
                Access            = $result.Access
                MatchedRuleName   = $result.Rule.Name
                Priority          = [int]$result.Rule.Priority
                RuleType          = $result.RuleType
                MatchedPrefix     = $result.MatchedPrefix
                RuleProtocol      = [string]$result.Rule.Protocol
                PortRange         = $result.PortRange
                Notes             = ($notes -join ' ')
            }

            Write-ScriptLog -Message "NSG '$($nsg.Name)' $currentDirection : $($result.Access) via rule '$($result.Rule.Name)' (priority $($result.Rule.Priority))." -Path $LogPath
        }
    }
}

end {
    Write-ScriptLog -Message "NSG evaluation completed. Log file: $LogPath" -Path $LogPath
}
