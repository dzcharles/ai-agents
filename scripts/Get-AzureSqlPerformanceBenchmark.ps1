#Requires -Version 7.0
#Requires -Modules Az.Accounts, SqlServer

<#
.SYNOPSIS
    Captures a read-only Azure SQL Database performance benchmark snapshot.

.DESCRIPTION
    Collects diagnostic data to compare workload characteristics before and after an index change.
    The script uses Entra authentication from the current Az.Accounts context and exports CSV files
    for index physical statistics, aggregated Query Store runtime statistics, recent resource usage,
    and allocated data and log file sizes. Cumulative wait statistics are optional.

    The script does not modify SQL data, schema, indexes, Query Store settings, or database
    configuration. Index physical statistics use LIMITED mode and only report user-object indexes
    with at least 1,000 pages. Each query has a configurable timeout to bound collection time.

.PARAMETER SqlInstance
    Fully qualified Azure SQL logical server name, for example contoso.database.windows.net.

.PARAMETER Database
    Azure SQL Database name to benchmark.

.PARAMETER Label
    Comparison label for this capture. Use Before before an index change and After afterwards.

.PARAMETER OutputPath
    Directory where the timestamped benchmark folder is created. Defaults to the current directory.

.PARAMETER QueryStoreLookbackDays
    Number of recent days included in the Query Store aggregation. Defaults to 7 and is limited to
    1 through 30 days.

.PARAMETER QueryTimeoutSeconds
    Timeout applied to each diagnostic query. Defaults to 60 seconds and is limited to 5 through
    300 seconds.

.PARAMETER IncludeWaitStats
    Includes a cumulative wait-statistics snapshot. This is source-state information, not a
    before-and-after delta, because counters can be reset by service events or failovers.

.EXAMPLE
    ./Get-AzureSqlPerformanceBenchmark.ps1 -SqlInstance 'contoso.database.windows.net' -Database 'Sales' -Label Before

.EXAMPLE
    ./Get-AzureSqlPerformanceBenchmark.ps1 -SqlInstance 'contoso.database.windows.net' -Database 'Sales' -Label After -OutputPath './benchmark-output' -IncludeWaitStats

.OUTPUTS
    System.Management.Automation.PSCustomObject
    A summary containing the generated files, capture metadata, and metric limitations.

.NOTES
    Requires PowerShell 7+, Az.Accounts, SqlServer, and an existing Entra authentication context.
    The Entra principal must be able to connect to the database and typically requires
    VIEW DATABASE STATE to read the diagnostic views. Query Store must be enabled to export its
    runtime statistics. Query text is deliberately not exported because it can contain sensitive data.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SqlInstance,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Database,

    [Parameter(Mandatory)]
    [ValidateSet('Before', 'After')]
    [string]$Label,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = (Get-Location).Path,

    [Parameter()]
    [ValidateRange(1, 30)]
    [int]$QueryStoreLookbackDays = 7,

    [Parameter()]
    [ValidateRange(5, 300)]
    [int]$QueryTimeoutSeconds = 60,

    [Parameter()]
    [switch]$IncludeWaitStats
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-BenchmarkDependency {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ModuleName,

        [Parameter(Mandatory)]
        [string]$CommandName
    )

    if (-not (Get-Module -ListAvailable -Name $ModuleName)) {
        throw "Required module '$ModuleName' is not installed. Install an approved version before running this script."
    }

    if (-not (Get-Command -Name $CommandName -ErrorAction SilentlyContinue)) {
        throw "Required command '$CommandName' from module '$ModuleName' is unavailable."
    }
}

function ConvertTo-PlainTextAccessToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Token
    )

    if ($Token -isnot [securestring]) {
        return [string]$Token
    }

    $tokenPointer = [IntPtr]::Zero
    try {
        $tokenPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Token)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenPointer)
    }
    finally {
        if ($tokenPointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPointer)
        }
    }
}

function Invoke-BenchmarkQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Query,

        [Parameter(Mandatory)]
        [string]$AccessToken,

        [Parameter(Mandatory)]
        [int]$QueryTimeoutSeconds
    )

    Write-Verbose -Message "Running read-only query '$Name'."
    try {
        return @(Invoke-Sqlcmd -ServerInstance $SqlInstance -Database $Database -AccessToken $AccessToken -Query $Query -QueryTimeout $QueryTimeoutSeconds -ConnectionTimeout 15 -AbortOnError -ErrorAction Stop)
    }
    catch {
        throw "Read-only query '$Name' failed: $($_.Exception.Message)"
    }
}

function Export-BenchmarkCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$InputObject,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($InputObject.Count -eq 0) {
        Set-Content -LiteralPath $Path -Value '' -Encoding utf8 -ErrorAction Stop
        Write-Warning "No rows were returned for '$Path'; an empty CSV was created."
        return
    }

    $InputObject | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8 -ErrorAction Stop
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$benchmarkPath = Join-Path -Path $OutputPath -ChildPath "AzureSqlPerformanceBenchmark-$Label-$timestamp"

$indexPhysicalStatsQuery = @'
SELECT
    DB_NAME() AS DatabaseName,
    SCHEMA_NAME(objectMetadata.schema_id) AS SchemaName,
    objectMetadata.name AS ObjectName,
    indexMetadata.name AS IndexName,
    physicalStats.index_type_desc AS IndexType,
    physicalStats.partition_number AS PartitionNumber,
    physicalStats.page_count AS PageCount,
    physicalStats.avg_fragmentation_in_percent AS AverageFragmentationPercent,
    physicalStats.avg_page_space_used_in_percent AS AveragePageSpaceUsedPercent,
    physicalStats.fragment_count AS FragmentCount,
    SYSUTCDATETIME() AS CapturedAtUtc
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') AS physicalStats
INNER JOIN sys.objects AS objectMetadata
    ON physicalStats.object_id = objectMetadata.object_id
INNER JOIN sys.indexes AS indexMetadata
    ON physicalStats.object_id = indexMetadata.object_id
    AND physicalStats.index_id = indexMetadata.index_id
WHERE objectMetadata.is_ms_shipped = 0
    AND objectMetadata.type = 'U'
    AND physicalStats.index_id > 0
    AND physicalStats.page_count >= 1000
ORDER BY physicalStats.avg_fragmentation_in_percent DESC, physicalStats.page_count DESC;
'@

$queryStoreQuery = @"
DECLARE @WindowStartUtc datetime2(7) = DATEADD(DAY, -$QueryStoreLookbackDays, SYSUTCDATETIME());
DECLARE @WindowEndUtc datetime2(7) = SYSUTCDATETIME();

SELECT TOP (25)
    DB_NAME() AS DatabaseName,
    queryStoreQuery.query_id AS QueryId,
    queryStorePlan.plan_id AS PlanId,
    queryStoreQuery.query_hash AS QueryHash,
    SUM(runtimeStats.count_executions) AS ExecutionCount,
    CAST(SUM(runtimeStats.avg_duration * runtimeStats.count_executions) / NULLIF(SUM(runtimeStats.count_executions), 0) / 1000.0 AS decimal(18, 2)) AS WeightedAverageDurationMilliseconds,
    CAST(SUM(runtimeStats.avg_cpu_time * runtimeStats.count_executions) / NULLIF(SUM(runtimeStats.count_executions), 0) / 1000.0 AS decimal(18, 2)) AS WeightedAverageCpuMilliseconds,
    CAST(SUM(runtimeStats.avg_logical_io_reads * runtimeStats.count_executions) / NULLIF(SUM(runtimeStats.count_executions), 0) AS decimal(18, 2)) AS WeightedAverageLogicalReads,
    SUM(runtimeStats.avg_duration * runtimeStats.count_executions) / 1000.0 AS TotalDurationMilliseconds,
    @WindowStartUtc AS WindowStartUtc,
    @WindowEndUtc AS WindowEndUtc,
    SYSUTCDATETIME() AS CapturedAtUtc
FROM sys.query_store_runtime_stats AS runtimeStats
INNER JOIN sys.query_store_runtime_stats_interval AS runtimeInterval
    ON runtimeStats.runtime_stats_interval_id = runtimeInterval.runtime_stats_interval_id
INNER JOIN sys.query_store_plan AS queryStorePlan
    ON runtimeStats.plan_id = queryStorePlan.plan_id
INNER JOIN sys.query_store_query AS queryStoreQuery
    ON queryStorePlan.query_id = queryStoreQuery.query_id
WHERE runtimeInterval.end_time > @WindowStartUtc
    AND runtimeInterval.start_time < @WindowEndUtc
GROUP BY queryStoreQuery.query_id, queryStorePlan.plan_id, queryStoreQuery.query_hash
ORDER BY TotalDurationMilliseconds DESC;
"@

$resourceStatsQuery = @'
SELECT
    end_time AS IntervalEndUtc,
    avg_cpu_percent AS AverageCpuPercent,
    avg_data_io_percent AS AverageDataIoPercent,
    avg_log_write_percent AS AverageLogWritePercent,
    avg_memory_usage_percent AS AverageMemoryUsagePercent,
    max_worker_percent AS MaximumWorkerPercent,
    max_session_percent AS MaximumSessionPercent,
    SYSUTCDATETIME() AS CapturedAtUtc
FROM sys.dm_db_resource_stats
WHERE end_time >= DATEADD(HOUR, -1, SYSUTCDATETIME())
ORDER BY end_time ASC;
'@

$allocatedFileSizeQuery = @'
SELECT
    DB_NAME() AS DatabaseName,
    file_id AS FileId,
    name AS LogicalFileName,
    type_desc AS FileType,
    CAST(size / 128.0 AS decimal(18, 2)) AS AllocatedSizeMb,
    SYSUTCDATETIME() AS CapturedAtUtc
FROM sys.database_files
ORDER BY type_desc, file_id;
'@

$waitStatsQuery = @'
SELECT
    DB_NAME() AS DatabaseName,
    wait_type AS WaitType,
    waiting_tasks_count AS WaitingTasksCount,
    wait_time_ms AS WaitTimeMilliseconds,
    signal_wait_time_ms AS SignalWaitTimeMilliseconds,
    CAST(100.0 * wait_time_ms / NULLIF(SUM(wait_time_ms) OVER (), 0) AS decimal(9, 2)) AS PercentageOfCapturedWaitTime,
    SYSUTCDATETIME() AS CapturedAtUtc,
    'Cumulative source-state snapshot; not a benchmark-period delta.' AS Interpretation
FROM sys.dm_db_wait_stats
WHERE wait_type NOT LIKE 'SLEEP%'
    AND wait_type NOT IN ('BROKER_EVENTHANDLER', 'BROKER_RECEIVE_WAITFOR', 'BROKER_TASK_STOP', 'CLR_AUTO_EVENT', 'CLR_MANUAL_EVENT', 'DISPATCHER_QUEUE_SEMAPHORE', 'LAZYWRITER_SLEEP', 'ONDEMAND_TASK_QUEUE', 'REQUEST_FOR_DEADLOCK_SEARCH', 'SQLTRACE_BUFFER_FLUSH', 'WAITFOR', 'XE_DISPATCHER_WAIT', 'XE_TIMER_EVENT')
ORDER BY wait_time_ms DESC;
'@

try {
    Test-BenchmarkDependency -ModuleName 'Az.Accounts' -CommandName 'Get-AzAccessToken'
    Test-BenchmarkDependency -ModuleName 'SqlServer' -CommandName 'Invoke-Sqlcmd'

    $azContext = Get-AzContext -ErrorAction Stop
    if ($null -eq $azContext -or [string]::IsNullOrWhiteSpace($azContext.Account.Id)) {
        throw 'No active Az.Accounts context was found. Authenticate before execution with Connect-AzAccount.'
    }

    $tokenResponse = Get-AzAccessToken -ResourceUrl 'https://database.windows.net/' -ErrorAction Stop
    $sqlAccessToken = ConvertTo-PlainTextAccessToken -Token $tokenResponse.Token
    if ([string]::IsNullOrWhiteSpace($sqlAccessToken)) {
        throw 'Az.Accounts did not return an Azure SQL access token.'
    }

    New-Item -ItemType Directory -Path $benchmarkPath -ErrorAction Stop | Out-Null
    Write-Verbose -Message "Writing benchmark files to '$benchmarkPath'."

    $outputFiles = [System.Collections.Generic.List[string]]::new()
    $indexOutputPath = Join-Path -Path $benchmarkPath -ChildPath 'index-physical-stats.csv'
    Export-BenchmarkCsv -InputObject (Invoke-BenchmarkQuery -Name 'IndexPhysicalStats' -Query $indexPhysicalStatsQuery -AccessToken $sqlAccessToken -QueryTimeoutSeconds $QueryTimeoutSeconds) -Path $indexOutputPath
    $outputFiles.Add($indexOutputPath)

    $queryStoreOutputPath = Join-Path -Path $benchmarkPath -ChildPath 'query-store-top-queries.csv'
    Export-BenchmarkCsv -InputObject (Invoke-BenchmarkQuery -Name 'QueryStoreTopQueries' -Query $queryStoreQuery -AccessToken $sqlAccessToken -QueryTimeoutSeconds $QueryTimeoutSeconds) -Path $queryStoreOutputPath
    $outputFiles.Add($queryStoreOutputPath)

    $resourceOutputPath = Join-Path -Path $benchmarkPath -ChildPath 'resource-stats-last-hour.csv'
    Export-BenchmarkCsv -InputObject (Invoke-BenchmarkQuery -Name 'ResourceStatsLastHour' -Query $resourceStatsQuery -AccessToken $sqlAccessToken -QueryTimeoutSeconds $QueryTimeoutSeconds) -Path $resourceOutputPath
    $outputFiles.Add($resourceOutputPath)

    $fileSizeOutputPath = Join-Path -Path $benchmarkPath -ChildPath 'allocated-file-sizes.csv'
    Export-BenchmarkCsv -InputObject (Invoke-BenchmarkQuery -Name 'AllocatedFileSizes' -Query $allocatedFileSizeQuery -AccessToken $sqlAccessToken -QueryTimeoutSeconds $QueryTimeoutSeconds) -Path $fileSizeOutputPath
    $outputFiles.Add($fileSizeOutputPath)

    if ($IncludeWaitStats.IsPresent) {
        $waitOutputPath = Join-Path -Path $benchmarkPath -ChildPath 'wait-stats-snapshot.csv'
        Export-BenchmarkCsv -InputObject (Invoke-BenchmarkQuery -Name 'WaitStatsSnapshot' -Query $waitStatsQuery -AccessToken $sqlAccessToken -QueryTimeoutSeconds $QueryTimeoutSeconds) -Path $waitOutputPath
        $outputFiles.Add($waitOutputPath)
    }

    [pscustomobject]@{
        SqlInstance             = $SqlInstance
        Database                = $Database
        Label                   = $Label
        CapturedAtUtc           = (Get-Date).ToUniversalTime().ToString('o')
        OutputPath              = $benchmarkPath
        Files                   = $outputFiles
        DatabaseChangesMade     = $false
        QueryStoreLookbackDays  = $QueryStoreLookbackDays
        WaitStatsInterpretation = 'Optional cumulative source-state snapshot; not a before-and-after delta.'
        FileSizeInterpretation  = 'Allocated data and log file sizes only; not used or maximum database size.'
        QueryTextExported       = $false
    }
}
catch {
    $errorRecord = [System.Management.Automation.ErrorRecord]::new(
        $_.Exception,
        'AzureSqlBenchmarkFailed',
        [System.Management.Automation.ErrorCategory]::OperationStopped,
        "$SqlInstance/$Database"
    )
    $PSCmdlet.ThrowTerminatingError($errorRecord)
}