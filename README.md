# Azure Virtual Desktop Insights – Combined Baseline Query

## Purpose

This query provides a **single, unified view** of your Azure Virtual Desktop (AVD) session host health and performance metrics.  
Instead of running multiple independent queries (Time-to-Connect, RTT, CPU, Memory, Input Delay), this **combined query** joins them together into one summary table.

It uses official AVD Insights tables:

- `WVDConnections` → connection sessions  
- `WVDCheckpoints` → connection stage timestamps  
- `WVDConnectionNetworkData` → network quality (RTT, bandwidth)  
- `Perf` → performance counters (CPU, Memory, Input Delay)

---

## Official Source

This query and all metric definitions are **derived from**  
👉 [Microsoft Learn: Azure Virtual Desktop Insights Glossary](https://learn.microsoft.com/en-us/azure/virtual-desktop/insights-glossary)

That glossary defines how AVD Insights metrics (Time-to-Connect, Connection stages, RTT, CPU, Memory, Input Delay, etc.) are calculated and collected through the `WVDConnections`, `WVDCheckpoints`, `WVDConnectionNetworkData`, and `Perf` tables.


## Why This Query Matters

Running this combined query allows you to:

- Establish a **performance baseline** across all AVD session hosts.
- Detect outliers (slow logons, high latency, overloaded VMs) quickly.
- Compare **network health (RTT)** and **connection performance (TTC)** by region.
- Correlate end-user experience (Input Delay) with backend VM performance.

This is not a point-in-time diagnostic — it’s a **trend-based health snapshot** for engineering baselines and tuning.

---

##  How to Run It

1. Open **Azure Portal** → **Monitor** → **Logs** under your AVD **Log Analytics workspace**.
2. Set **Time range** to the desired window (for example, *Last 24 hours*).
3. Paste the combined query (from `combined-avd-insights.kql`) and click **Run**.
4. Optionally, **pin the result** to a Workbook for ongoing monitoring.

The query can be executed safely in any environment that has the standard AVD Insights data tables.

---

##  Example Output (Sample Host)

| Host | GatewayRegion | Connections | TTC_avg_s | TTC_p95_s | RTT_p50_ms | RTT_p95_ms | CPU_avg | CPU_p95 | MEM_avg | MEM_p95 | Input_p95_ms |
|------|----------------|--------------|------------|------------|-------------|-------------|----------|----------|----------|----------|----------------|
| vmdem2dusw30001 | eastus2 | 1 | 90.6 | 90.6 | 72 | 78 | 6.1 | 21.1 | NaN | 21.1 | 0 |

---

##  Understanding Each Column

| Metric | Description | Expected Range / Notes |
|---------|--------------|-----------------------|
| **Host** | The session host VM name. | Identifies which AVD VM the data belongs to. |
| **GatewayRegion** | Azure region handling the client connection. | Indicates proximity; typically matches the host region. |
| **Connections** | Number of connections during the lookback window. | Used for statistical weighting. |
| **TTC_avg_s / TTC_p95_s** | *Time-to-Connect* in seconds from connection start → shell ready. | Ideal logon time: **30 s – 5 min** depending on FSLogix, GPO, and startup apps. Higher indicates profile or policy delays. |
| **RTT_p50_ms / RTT_p95_ms** | *Round-Trip Time* in milliseconds between client and AVD gateway. | Below **100 ms** = good; > 150 ms = potential WAN latency. |
| **CPU_avg / CPU_p95** | Average and 95th percentile CPU utilization from the VM. | 5 – 60 % is typical. > 80 % means host may be overloaded. |
| **MEM_avg / MEM_p95** | Average and 95th percentile memory usage (% committed bytes). | Should remain below 80 %. `NaN` means the counter wasn’t collected. |
| **Input_p95_ms** | 95th percentile of *User Input Delay* (keyboard/mouse lag). | < 100 ms ideal. High values indicate UI lag or network jitter. |

---

##  Example Interpretation (from the table above)

- **TTC (90 s)** → Slightly long; likely due to backend startup (FSLogix, GPO).  
- **RTT (72–78 ms)** → Normal latency; healthy regional routing.  
- **CPU (6–21 %)** → Well within acceptable range.  
- **MEM (21 %)** → Low utilization or missing samples (NaN average).  
- **Input Delay (0 ms)** → Excellent user responsiveness.

> ⚙️ This example shows a **healthy baseline** where login time is elevated mainly because background apps and services initialize slowly — expected in development or “cold start” scenarios.

---

## Baseline Guidelines

| Metric | Healthy Range | Observations |
|---------|----------------|--------------|
| **Time-to-Connect (TTC)** | 30 s – 5 min | Varies by FSLogix, GPOs, startup apps. |
| **Round Trip Time (RTT)** | < 100 ms (p95) | Higher values = cross-region or poor client network. |
| **CPU (p95)** | < 80 % | Sustained > 90 % indicates scaling needed. |
| **Memory (p95)** | < 80 % | Check for leaks or session bloat if higher. |
| **Input Delay (p95)** | < 100 ms | Higher indicates user lag. |

---

## Value to Teams

- **Ops** → Quickly identify slow hosts or bad regions.  
- **Infra Engineers** → Validate autoscale / VM sizing decisions.  
- **Support** → Use as “known good baseline” to compare user complaints.  
- **Developers** → Measure impact of backend startup code on user experience.

---

## Notes

- These metrics **will vary by environment** (FSLogix configuration, VM SKU, app load).  
- The “ideal” values above are guidance based on Microsoft’s internal AVD Insights benchmarks.  
- Treat this as a **baseline** — not a performance SLA.  
- For best accuracy, collect data over **3–5 days** of normal load before setting thresholds.

---

**Source:** [Microsoft Learn – Azure Virtual Desktop Insights Glossary](https://learn.microsoft.com/en-us/azure/virtual-desktop/insights-glossary)  
**Purpose:** Baseline health assessment of AVD session hosts through combined KQL analysis.
