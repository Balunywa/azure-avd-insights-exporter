# Azure Virtual Desktop (AVD) Insights Collector

## 📘 Overview
This PowerShell script (`Get-AVD-Insights-Extended.ps1`) automates the collection and export of **Azure Virtual Desktop Insights** metrics from a Log Analytics Workspace.

It retrieves detailed telemetry defined in Microsoft’s [AVD Insights Glossary](https://learn.microsoft.com/en-us/azure/virtual-desktop/insights-glossary), including:
- **Time to Connect** (overall and component breakdowns)
- **Connection success rate & daily trends**
- **User Input Delay (median/p95)**
- **RTT (Round Trip Time)** by Gateway Region
- **Estimated Bandwidth (kBps)** by Gateway Region
- **CPU and Memory utilization** per session host and environment-wide
- (Optional) **Process I/O performance** from your own CSV (e.g., disk and I/O metrics)

All collected data is saved into a single **Excel workbook**, with an optional **PDF export** for easy sharing and review.

---

## 🎯 Purpose
Azure Virtual Desktop offers rich telemetry via Log Analytics, but querying and correlating the data manually can be time-consuming and inconsistent.

This script provides:
- A **repeatable, automated baseline** for performance, latency, and user experience analysis.
- A **comprehensive snapshot** of AVD health across hosts, users, and gateway regions.
- **Faster troubleshooting** by surfacing key metrics (RTT, logon time, CPU, memory, input delay) in one place.
- A **developer-friendly foundation** for building your own dashboards or automation pipelines.

---

## ⚠️ Important: Dev/Non-Production Use Only
> 🚨 **This script must only be run in development or test environments.**
>
> - It uses diagnostic queries that can generate large volumes of data.
> - It performs real-time analytics against your Log Analytics workspace and may incur query costs.
> - It is designed for **engineering validation, baselining, or lab testing** — **not** for production automation or scheduled monitoring.
> - Always validate in a sandboxed environment before considering any adaptation for production.

---

## 🧩 Value
- **Consolidation:** Combines metrics from multiple KQL tables (`WVDConnections`, `WVDCheckpoints`, `Perf`, `WVDConnectionNetworkData`) into a single export.
- **Transparency:** Maps directly to the metrics Microsoft defines in the official AVD Insights documentation.
- **Flexibility:** Supports optional inclusion of your own per-process I/O metrics.
- **Ease of analysis:** Data is written to structured Excel worksheets — perfect for filtering, graphing, and trend analysis.

---

## 🚀 How to Use

### 1. Prerequisites
- PowerShell 7+ (recommended)
- Modules:
  ```powershell
  Install-Module Az.Accounts,Az.OperationalInsights,ImportExcel -Scope CurrentUser -Force
A valid Azure Log Analytics Workspace ID with AVD Insights data.

Optional: Excel (for PDF export).

2. Running the Script
Basic usage (24-hour lookback)
powershell
Copy code
.\Get-AVD-Insights-Extended.ps1 -WorkspaceId "<YOUR-LAW-GUID>" -LookbackHours 24 -OutputFolder "C:\AVDReports"
With optional PDF export
powershell
Copy code
.\Get-AVD-Insights-Extended.ps1 -WorkspaceId "<YOUR-LAW-GUID>" -ExportPdf
Including your process performance CSV
powershell
Copy code
.\Get-AVD-Insights-Extended.ps1 -WorkspaceId "<YOUR-LAW-GUID>" `
  -ProcessCsv "C:\path\process_io_times_converted.csv" -ExportPdf
3. Output Files
Each run generates a timestamped Excel workbook and (optional) PDF:

swift
Copy code
C:\AVDReports\
 ├── AVD-Insights_YYYYMMDD_HHMM.xlsx
 ├── AVD-Insights_YYYYMMDD_HHMM.pdf  (optional)
Excel Workbook Tabs
Sheet	Description
TimeToConnect	Total time users take to connect (p50/p95)
TTC_Components	Breakdown by stage: UserRoute, StackConnected, Logon, ShellReady
ConnectionSuccess	Total, completed, and connected sessions with success rate
DailyConnections	Connection counts per day
InputDelay	User Input Delay per process (median & p95)
RTT_ByGateway	Median/p95 RTT (ms) by gateway region
RTT_TS_ByGateway	10-min RTT time series per gateway region
RTT_TS_AllRegions	Environment-wide RTT time series
Bandwidth_ByGateway	Estimated available bandwidth per region
Host_CPU_Memory	Host-level CPU and memory utilization (p50/p95/avg)
CPU_TimeSeries / Memory_TimeSeries	5-min time series per host
CPU_Env_TimeSeries / Mem_Env_TimeSeries	Aggregate environment time series
ProcessIO (optional)	Your per-process disk & I/O performance data
ProcessIO_Summary (optional)	Totals for disk, I/O, and count statistics

🧠 Understanding the Data
All queries and metric definitions map directly to Microsoft’s Azure Virtual Desktop Insights Glossary.
Key sources include:

WVDConnections, WVDCheckpoints — for connection stages and time-to-connect metrics

WVDConnectionNetworkData — for RTT and bandwidth by gateway region

Perf — for CPU, memory, and input delay counters

User Input Delay per Process — for user experience metrics

🧰 Example Use Cases
Benchmarking login and session performance during golden image updates.

Comparing RTT across gateway regions to diagnose connectivity variance.

Analyzing CPU/memory saturation trends across session hosts.

Correlating disk I/O performance from your CSV to session delays.

Producing an on-demand AVD performance baseline for internal reviews.

🛑 Disclaimer
This script is provided as-is, without warranty or support.
It is intended for development and testing only.
Running it in production or attaching it to automated pipelines may cause performance and cost impacts in your Azure environment.

🏷️ License
MIT License – feel free to fork, extend, and improve
