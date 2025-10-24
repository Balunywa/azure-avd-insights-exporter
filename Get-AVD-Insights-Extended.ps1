param(
    [Parameter(Mandatory=$true)][string]$WorkspaceId,           # Log Analytics Workspace ID (GUID)
    [int]$LookbackHours = 24,                                   # Time window
    [string]$OutputFolder = ".\AVD-Report",
    [string]$ProcessCsv,                                        # Optional: CSV like your process table
    [switch]$ExportPdf                                          # Export PDF (requires Microsoft Excel)
)

# -------------------------- Helpers -----------------------------------------
function Ensure-Module {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Get-Module -ListAvailable -Name $Name)) {
        Install-Module $Name -Scope CurrentUser -Force -ErrorAction Stop
    }
    Import-Module $Name -Force
}
function Run-Kql {
    param([string]$Query)
    Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId `
        -Query $Query -Timespan (New-TimeSpan -Hours $LookbackHours) -ErrorAction Stop
}
function Convert-Results { param($r) if ($r.Results) { $r.Results } else { @() } }

# Gateway region code -> friendly Azure region name (subset from MSFT list; unknown codes left as-is)
$GatewayMap = @{
  AUC="Australia Central";AUC2="Australia Central 2";AUE="Australia East";AUSE="Australia Southeast";
  BRS="Brazil South";CAC="Canada Central";CAE="Canada East";CHNO="Switzerland North";
  CIN="Central India";CUS="Central US";EAS="East Asia";EEU="East Europe";EUS="East US";EUS2="East US 2";
  FRC="France Central";FRAS="France South";GEC="Germany Central";GEN="Germany North";GENE="Germany Northeast";
  GWC="Germany West Central";JPE="Japan East";JPW="Japan West";KRC="Korea Central";KRS="Korea South";KRS2="Korea South 2";
  NCUS="North Central US";NEU="North Europe";NOE="Norway East";NOW="Norway West";SAN="South Africa North";SAW="South Africa West";
  SCUS="South Central US";SEAS="Southeast Asia";SEA2="Southeast Asia 2";SIN="South India";SWW="Switzerland West";
  UAEC="UAE Central";UAEN="UAE North";UKN="UK North";UKS="UK South";UKS2="UK South 2";UKW="UK West";
  WCUS="West Central US";WEU="West Europe";WIN="West India";WUS="West US"
}

# -------------------------- Prereqs -----------------------------------------
$ErrorActionPreference = 'Stop'
Ensure-Module Az.Accounts
Ensure-Module Az.OperationalInsights
Ensure-Module ImportExcel

if (-not (Get-AzContext)) {
    Write-Host "Logging in to Azure..." -ForegroundColor Cyan
    Connect-AzAccount | Out-Null
}

# -------------------------- KQL: Time to connect (overall & components) -----
$kqlTimeToConnect = @'
let endsDesktop = WVDCheckpoints | where Name == "ShellReady" | project CorrelationId, EndTime=TimeGenerated;
let endsApp     = WVDCheckpoints | where Name == "RdpShellAppExecuted" | project CorrelationId, EndTime=TimeGenerated;
let ends = union endsDesktop, endsApp;
WVDConnections
| where State == "Started"
| project CorrelationId, StartTime=TimeGenerated, UserName, SessionHostName, ClientOS, ResourceId=_ResourceId
| join kind=leftouter ends on CorrelationId
| where isnotempty(EndTime)
| extend TimeToConnect_s = datetime_diff('second', EndTime, StartTime)
| summarize avg_s=avg(TimeToConnect_s), p50_s=percentile(TimeToConnect_s,50), p95_s=percentile(TimeToConnect_s,95), connections=count() by bin(StartTime, 1h)
| order by StartTime asc
'@

$kqlTtcComponents = @'
let starts = WVDConnections | where State == "Started" | project CorrelationId, StartTime=TimeGenerated;
let cp = WVDCheckpoints | project CorrelationId, Name, T=TimeGenerated;
let endCp  = cp | where Name in ("ShellReady","RdpShellAppExecuted") | summarize EndT=min(T) by CorrelationId;
let route  = cp | where Name == "UserRouteComplete" | summarize RouteT=min(T) by CorrelationId;
let stack  = cp | where Name == "StackConnected"     | summarize StackT=min(T)  by CorrelationId;
let shell  = cp | where Name == "ShellStart"         | summarize ShellT=min(T)  by CorrelationId;
starts
| join kind=leftouter endCp on CorrelationId
| join kind=leftouter route on CorrelationId
| join kind=leftouter stack on CorrelationId
| join kind=leftouter shell on CorrelationId
| where isnotempty(EndT)
| extend TimeToConnect_s = datetime_diff('second', EndT, StartTime)
| extend UserRoute_s         = iif(isnull(RouteT), real(null), datetime_diff('second', RouteT, StartTime))
| extend StackConnected_s    = iif(isnull(StackT), real(null), datetime_diff('second', StackT, coalesce(RouteT, StartTime)))
| extend Logon_s             = iif(isnull(ShellT) or isnull(StackT), real(null), datetime_diff('second', ShellT, StackT))
| extend ShellStartToReady_s = iif(isnull(EndT) or isnull(ShellT), real(null), datetime_diff('second', EndT, ShellT))
| summarize connections=count(),
           avg_ttc=avg(TimeToConnect_s), p50_ttc=percentile(TimeToConnect_s,50), p95_ttc=percentile(TimeToConnect_s,95),
           avg_route=avg(UserRoute_s), avg_stack=avg(StackConnected_s), avg_logon=avg(Logon_s), avg_shell=avg(ShellStartToReady_s)
'@

$kqlConnSuccess = 'WVDConnections | summarize total=count(), completed=countif(State == "Completed"), connected=countif(State == "Connected") | extend success_rate = 100.0 * todouble(completed) / todouble(total)'
$kqlDaily       = 'WVDConnections | summarize connections=count() by bin(TimeGenerated, 1d) | order by TimeGenerated asc'

# -------------------------- NEW: RTT by gateway region ----------------------
# Uses WVDConnectionNetworkData (EstRoundTripTimeInMs) joined to WVDConnections.GatewayRegion
$kqlRttByGateway = @'
WVDConnectionNetworkData
| join kind=inner (WVDConnections | project CorrelationId, GatewayRegion) on CorrelationId
| summarize p50_rtt_ms=percentile(EstRoundTripTimeInMs, 50), p95_rtt_ms=percentile(EstRoundTripTimeInMs, 95),
            samples=count(), connections=dcount(CorrelationId) by GatewayRegion
| order by p50_rtt_ms desc
'@

$kqlRttTimeSeriesByGateway = @'
WVDConnectionNetworkData
| join kind=inner (WVDConnections | project CorrelationId, GatewayRegion) on CorrelationId
| summarize p50_ms=percentile(EstRoundTripTimeInMs, 50), p95_ms=percentile(EstRoundTripTimeInMs, 95)
          by bin(TimeGenerated, 10m), GatewayRegion
| order by TimeGenerated asc
'@

$kqlRttAllTimeSeries = @'
WVDConnectionNetworkData
| summarize p50_ms=percentile(EstRoundTripTimeInMs, 50), p95_ms=percentile(EstRoundTripTimeInMs, 95)
          by bin(TimeGenerated, 10m)
| order by TimeGenerated asc
'@

$kqlBandwidthByGateway = @'
WVDConnectionNetworkData
| join kind=inner (WVDConnections | project CorrelationId, GatewayRegion) on CorrelationId
| summarize p50_kBps=percentile(EstAvailableBandwidthKBps, 50), p95_kBps=percentile(EstAvailableBandwidthKBps, 95)
          by GatewayRegion
| order by p50_kBps asc
'@

# -------------------------- NEW: CPU / Memory counters ----------------------
# Counters per Insights glossary: Processor Information(_Total)\% Processor Time, Memory\% Committed Bytes in Use
$kqlHostCpuMem = @'
let cpu = Perf
| where (ObjectName == "Processor Information" or ObjectName == "Processor")
| where CounterName == "% Processor Time"
| where InstanceName == "_Total" or isempty(InstanceName)
| summarize cpu_p50=percentile(CounterValue,50), cpu_p95=percentile(CounterValue,95), cpu_avg=avg(CounterValue), cpu_samples=count() by Computer;
let mem = Perf
| where ObjectName == "Memory" and CounterName == "% Committed Bytes in Use"
| summarize mem_p50=percentile(CounterValue,50), mem_p95=percentile(CounterValue,95), mem_avg=avg(CounterValue) by Computer;
cpu | join kind=fullouter mem on Computer
| project Computer, cpu_avg, cpu_p50, cpu_p95, mem_avg, mem_p50, mem_p95, cpu_samples
| order by coalesce(cpu_p95,0) desc
'@

$kqlCpuTimeSeries = @'
Perf
| where (ObjectName == "Processor Information" or ObjectName == "Processor")
| where CounterName == "% Processor Time"
| where InstanceName == "_Total" or isempty(InstanceName)
| summarize avg_cpu=avg(CounterValue), p95_cpu=percentile(CounterValue,95) by bin(TimeGenerated, 5m), Computer
| order by TimeGenerated asc
'@

$kqlMemTimeSeries = @'
Perf
| where ObjectName == "Memory" and CounterName == "% Committed Bytes in Use"
| summarize avg_mem=avg(CounterValue), p95_mem=percentile(CounterValue,95) by bin(TimeGenerated, 5m), Computer
| order by TimeGenerated asc
'@

$kqlCpuEnvTimeSeries = @'
Perf
| where (ObjectName == "Processor Information" or ObjectName == "Processor")
| where CounterName == "% Processor Time"
| where InstanceName == "_Total" or isempty(InstanceName)
| summarize avg_cpu=avg(CounterValue), p95_cpu=percentile(CounterValue,95) by bin(TimeGenerated, 5m)
| order by TimeGenerated asc
'@

$kqlMemEnvTimeSeries = @'
Perf
| where ObjectName == "Memory" and CounterName == "% Committed Bytes in Use"
| summarize avg_mem=avg(CounterValue), p95_mem=percentile(CounterValue,95) by bin(TimeGenerated, 5m)
| order by TimeGenerated asc
'@

# -------------------------- Input delay (unchanged) -------------------------
$kqlInputDelay = @'
Perf
| where ObjectName == "User Input Delay per Process" and CounterName == "Max Input Delay"
| summarize median_ms=percentile(CounterValue, 50), p95_ms=percentile(CounterValue, 95) by Computer, InstanceName
| top 50 by p95_ms desc
'@

# -------------------------- Run queries -------------------------------------
Write-Host "Running KQL queries..." -ForegroundColor Cyan
$ttc             = Convert-Results (Run-Kql $kqlTimeToConnect)
$ttcComponents   = Convert-Results (Run-Kql $kqlTtcComponents)
$connSuccess     = Convert-Results (Run-Kql $kqlConnSuccess)
$daily           = Convert-Results (Run-Kql $kqlDaily)
$inputDelay      = Convert-Results (Run-Kql $kqlInputDelay)

# NEW: RTT & bandwidth
$rttByGateway    = Convert-Results (Run-Kql $kqlRttByGateway)
$rttTSByGateway  = Convert-Results (Run-Kql $kqlRttTimeSeriesByGateway)
$rttAllTS        = Convert-Results (Run-Kql $kqlRttAllTimeSeries)
$bwByGateway     = Convert-Results (Run-Kql $kqlBandwidthByGateway)

# NEW: CPU/Mem
$hostCpuMem      = Convert-Results (Run-Kql $kqlHostCpuMem)
$cpuTS           = Convert-Results (Run-Kql $kqlCpuTimeSeries)
$memTS           = Convert-Results (Run-Kql $kqlMemTimeSeries)
$cpuEnvTS        = Convert-Results (Run-Kql $kqlCpuEnvTimeSeries)
$memEnvTS        = Convert-Results (Run-Kql $kqlMemEnvTimeSeries)

# -------------------------- Workbook output ---------------------------------
New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
$ts   = Get-Date -Format 'yyyyMMdd_HHmm'
$xlsx = Join-Path $OutputFolder "AVD-Insights_$ts.xlsx"
$null = Remove-Item $xlsx -ErrorAction SilentlyContinue

# Core sheets
$ttc           | Export-Excel $xlsx -WorksheetName 'TimeToConnect'    -AutoFilter -AutoSize
$ttcComponents | Export-Excel $xlsx -WorksheetName 'TTC_Components'   -AutoFilter -AutoSize -Append
$connSuccess   | Export-Excel $xlsx -WorksheetName 'ConnectionSuccess' -AutoFilter -AutoSize -Append
$daily         | Export-Excel $xlsx -WorksheetName 'DailyConnections'  -AutoFilter -AutoSize -Append
$inputDelay    | Export-Excel $xlsx -WorksheetName 'InputDelay'        -AutoFilter -AutoSize -Append

# NEW: RTT & bandwidth sheets
if ($rttByGateway) {
    # add friendly region name column
    $rttByGateway | ForEach-Object {
        $code = $_.GatewayRegion
        $_ | Add-Member -NotePropertyName 'GatewayRegionName' -NotePropertyValue ($GatewayMap[$code] ?? $code) -Force
    }
}
$rttByGateway   | Export-Excel $xlsx -WorksheetName 'RTT_ByGateway'        -AutoFilter -AutoSize -Append
$rttTSByGateway | Export-Excel $xlsx -WorksheetName 'RTT_TS_ByGateway'     -AutoFilter -AutoSize -Append
$rttAllTS       | Export-Excel $xlsx -WorksheetName 'RTT_TS_AllRegions'    -AutoFilter -AutoSize -Append
$bwByGateway    | Export-Excel $xlsx -WorksheetName 'Bandwidth_ByGateway'  -AutoFilter -AutoSize -Append

# NEW: CPU & Memory sheets
$hostCpuMem     | Export-Excel $xlsx -WorksheetName 'Host_CPU_Memory'      -AutoFilter -AutoSize -Append
$cpuTS          | Export-Excel $xlsx -WorksheetName 'CPU_TimeSeries'       -AutoFilter -AutoSize -Append
$memTS          | Export-Excel $xlsx -WorksheetName 'Memory_TimeSeries'    -AutoFilter -AutoSize -Append
$cpuEnvTS       | Export-Excel $xlsx -WorksheetName 'CPU_Env_TimeSeries'   -AutoFilter -AutoSize -Append
$memEnvTS       | Export-Excel $xlsx -WorksheetName 'Mem_Env_TimeSeries'   -AutoFilter -AutoSize -Append

# Optional: include your per-process I/O CSV (same format as we shared earlier)
if ($ProcessCsv -and (Test-Path $ProcessCsv)) {
    $proc = Import-Csv $ProcessCsv
    if ($proc -and ($proc[0].PSObject.Properties.Name -contains 'Disk Service Time (µs)') -and ($proc[0].PSObject.Properties.Name -contains 'I/O Time (µs)')) {
        $proc | ForEach-Object {
            $_ | Add-Member -NotePropertyName 'Disk Time (s)' -NotePropertyValue ([double]$_.('Disk Service Time (µs)')/1e6) -Force
            $_ | Add-Member -NotePropertyName 'I/O Time (s)'  -NotePropertyValue ([double]$_.('I/O Time (µs)')/1e6) -Force
            $_ | Add-Member -NotePropertyName 'Total Time (s)' -NotePropertyValue (([double]$_.('Disk Service Time (µs)') + [double]$_.('I/O Time (µs)'))/1e6) -Force
        }
        $sum = [pscustomobject]@{
            'Total Disk (s)'  = [math]::Round(($proc | Measure-Object -Property 'Disk Time (s)' -Sum).Sum, 3)
            'Total I/O (s)'   = [math]::Round(($proc | Measure-Object -Property 'I/O Time (s)' -Sum).Sum, 3)
            'Grand Total (s)' = [math]::Round(($proc | Measure-Object -Property 'Total Time (s)' -Sum).Sum, 3)
            'Total Ops'       = ($proc | Measure-Object -Property Count -Sum).Sum
            'Total Bytes'     = ($proc | Measure-Object -Property 'Data Size (Bytes)' -Sum).Sum
        }
        $sum | Export-Excel $xlsx -WorksheetName 'ProcessIO_Summary' -AutoFilter -AutoSize -Append
    }
    $proc | Export-Excel $xlsx -WorksheetName 'ProcessIO' -AutoFilter -AutoSize -Append
}

Write-Host "Excel written to: $xlsx" -ForegroundColor Green

# Optional: Export to PDF (requires Microsoft Excel installed)
if ($ExportPdf) {
    $pdf = [System.IO.Path]::ChangeExtension($xlsx, '.pdf')
    try {
        $excel = New-Object -ComObject Excel.Application
        $excel.Visible = $false
        $wb = $excel.Workbooks.Open((Resolve-Path $xlsx))
        # 0 = xlTypePDF
        $wb.ExportAsFixedFormat(0, (Resolve-Path $pdf))
        $wb.Close($false)
        $excel.Quit()
        Write-Host "PDF written to: $pdf" -ForegroundColor Green
    }
    catch {
        Write-Warning "Could not export PDF. Ensure Microsoft Excel is installed. $_"
    }
}
