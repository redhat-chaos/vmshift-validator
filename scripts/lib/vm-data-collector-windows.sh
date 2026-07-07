#!/usr/bin/env bash
# scripts/lib/vm-data-collector-windows.sh — Windows VM workload data collection via QEMU guest agent.
#
# Requires lib/guest-agent.sh (run_on_vm_via_agent) to be sourced first.
#
# Usage:
#   VM_DATA=$(collect_vm_data_windows [pre_log_size] [pre_db_size])
#
# Produces identical KEY=value output as vm-data-collector.sh so that
# pre/post migration checks and verdict logic work unchanged.

[[ -n "${_VM_DATA_COLLECTOR_WIN_LOADED:-}" ]] && return 0
_VM_DATA_COLLECTOR_WIN_LOADED=1

collect_vm_data_windows() {
  local pre_log_size="${1:-0}"
  local pre_db_size="${2:-0}"

  local prefix_sha_block=""
  if [[ "$pre_log_size" =~ ^[0-9]+$ ]] && [[ "$pre_log_size" -gt 0 ]]; then
    prefix_sha_block="${prefix_sha_block}
try {
  \$bytes = [System.IO.File]::ReadAllBytes('C:\\data\\test\\log.txt')
  if (\$bytes.Length -ge ${pre_log_size}) {
    \$prefix = New-Object byte[] ${pre_log_size}
    [Array]::Copy(\$bytes, \$prefix, ${pre_log_size})
    \$sha = [System.Security.Cryptography.SHA256]::Create()
    \$hash = [BitConverter]::ToString(\$sha.ComputeHash(\$prefix)).Replace('-','').ToLower()
    Write-Output \"PREFIX_LOG_SHA=\$hash\"
  } else {
    \$sha = [System.Security.Cryptography.SHA256]::Create()
    \$hash = [BitConverter]::ToString(\$sha.ComputeHash(\$bytes)).Replace('-','').ToLower()
    Write-Output \"PREFIX_LOG_SHA=\$hash\"
  }
} catch { Write-Output 'PREFIX_LOG_SHA=none' }"
  fi

  if [[ "$pre_db_size" =~ ^[0-9]+$ ]] && [[ "$pre_db_size" -gt 0 ]]; then
    prefix_sha_block="${prefix_sha_block}
try {
  \$bytes = [System.IO.File]::ReadAllBytes('C:\\data\\test\\test.db')
  if (\$bytes.Length -ge ${pre_db_size}) {
    \$prefix = New-Object byte[] ${pre_db_size}
    [Array]::Copy(\$bytes, \$prefix, ${pre_db_size})
    \$sha = [System.Security.Cryptography.SHA256]::Create()
    \$hash = [BitConverter]::ToString(\$sha.ComputeHash(\$prefix)).Replace('-','').ToLower()
    Write-Output \"PREFIX_DB_SHA=\$hash\"
  } else {
    \$sha = [System.Security.Cryptography.SHA256]::Create()
    \$hash = [BitConverter]::ToString(\$sha.ComputeHash(\$bytes)).Replace('-','').ToLower()
    Write-Output \"PREFIX_DB_SHA=\$hash\"
  }
} catch { Write-Output 'PREFIX_DB_SHA=none' }"
  fi

  # Build a single PowerShell script that outputs all KEY=value lines
  local ps_script
  ps_script=$(cat <<'PSEOF'
$ErrorActionPreference = 'SilentlyContinue'

# Timestamps
$now = [DateTime]::UtcNow
Write-Output "CAPTURE_TIME_UTC=$($now.ToString('yyyy-MM-ddTHH:mm:ss')) UTC"
Write-Output "CAPTURE_TIME_LOCAL=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')"

# File writer
try {
  $logFile = 'C:\data\test\log.txt'
  if (Test-Path $logFile) {
    $content = Get-Content $logFile
    $lines = if ($content) { @($content).Count } else { 0 }
    $fi = Get-Item $logFile
    $size = $fi.Length
    $last = if ($lines -gt 0) { @($content)[-1].Substring(0, [Math]::Min(@($content)[-1].Length, 256)) } else { 'none' }
  } else {
    $lines = 0; $size = 0; $last = 'none'
  }
} catch { $lines = 0; $size = 0; $last = 'none' }
Write-Output "FILE_WRITER_LINES=$lines"
Write-Output "FILE_WRITER_SIZE=$size"
Write-Output "FILE_WRITER_LAST=$last"

try {
  $fwProc = Get-WmiObject Win32_Process | Where-Object { $_.Name -like 'python*' -and $_.CommandLine -match 'file-writer' } | Select-Object -First 1
  $fwPid = if ($fwProc) { $fwProc.ProcessId } else { 'none' }
} catch { $fwPid = 'none' }
Write-Output "FILE_WRITER_PID=$fwPid"

# SQLite — uses table 'test' with schema (id, timestamp INTEGER, written_at TEXT)
try {
  $pyCode = @"
import sqlite3, json, time, datetime
try:
    c = sqlite3.connect(r'C:\data\test\test.db')
    rows = c.execute('SELECT count(*) FROM test').fetchone()[0]
    integrity = c.execute('PRAGMA integrity_check').fetchone()[0]
    all_ts = [r[0] for r in c.execute('SELECT timestamp FROM test ORDER BY id').fetchall()]
    epochs = [int(t) for t in all_ts if t]
    gaps = [epochs[i] - epochs[i-1] for i in range(1, len(epochs))]
    gaps_gt2 = sum(1 for g in gaps if g > 2)
    max_gap = max(gaps) if gaps else 0
    max_epoch = max(epochs) if epochs else 0
    min_epoch = min(epochs) if epochs else 0
    print(f'SQLITE_ROWS={rows}')
    print(f'SQLITE_MAX_TS={max_epoch}')
    print(f'SQLITE_MIN_TS={min_epoch}')
    print(f'SQLITE_INTEGRITY={integrity}')
    print(f'SQLITE_GAPS_GT2={gaps_gt2}')
    print(f'SQLITE_MAX_GAP={max_gap}')
except Exception:
    print('SQLITE_ROWS=0')
    print('SQLITE_MAX_TS=0')
    print('SQLITE_MIN_TS=0')
    print('SQLITE_INTEGRITY=unknown')
    print('SQLITE_GAPS_GT2=-1')
    print('SQLITE_MAX_GAP=-1')
"@
  $pyResult = & 'C:\Program Files\Python312\python.exe' -c $pyCode 2>$null
  if ($pyResult) { $pyResult | ForEach-Object { Write-Output $_ } }
  else { throw 'no output' }
} catch {
  Write-Output 'SQLITE_ROWS=0'
  Write-Output 'SQLITE_MAX_TS=0'
  Write-Output 'SQLITE_MIN_TS=0'
  Write-Output 'SQLITE_INTEGRITY=unknown'
  Write-Output 'SQLITE_GAPS_GT2=-1'
  Write-Output 'SQLITE_MAX_GAP=-1'
}

try {
  $dbFile = 'C:\data\test\test.db'
  if (Test-Path $dbFile) {
    Write-Output "SQLITE_SIZE=$((Get-Item $dbFile).Length)"
  } else { Write-Output 'SQLITE_SIZE=0' }
} catch { Write-Output 'SQLITE_SIZE=0' }

try {
  $sqProc = Get-WmiObject Win32_Process | Where-Object { $_.Name -like 'python*' -and $_.CommandLine -match 'sqlite-writer' } | Select-Object -First 1
  $sqPid = if ($sqProc) { $sqProc.ProcessId } else { 'none' }
} catch { $sqPid = 'none' }
Write-Output "SQLITE_PID=$sqPid"

# Cron — not available on Windows, hardcode to trigger auto-SKIP in verdict
Write-Output 'CRON_LINES=0'
Write-Output 'CRON_LAST=none'
Write-Output 'CROND_STATUS=inactive'
Write-Output 'CRONTAB_ENTRY=none'

# HTTP server
try {
  $resp = Invoke-WebRequest -Uri 'http://localhost:8080' -UseBasicParsing -TimeoutSec 5
  $httpCode = $resp.StatusCode
} catch { $httpCode = 0 }
Write-Output "HTTP_STATUS=$httpCode"

try {
  $httpProc = Get-WmiObject Win32_Process | Where-Object { $_.Name -like 'python*' -and $_.CommandLine -match 'http-server' } | Select-Object -First 1
  $httpPid = if ($httpProc) { $httpProc.ProcessId } else { 'none' }
} catch { $httpPid = 'none' }
Write-Output "HTTP_PID=$httpPid"

# VM info
Write-Output "VM_HOSTNAME=$(hostname)"

try {
  $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1).IPAddress
  if (-not $ip) { $ip = 'unknown' }
} catch { $ip = 'unknown' }
Write-Output "VM_IP_INTERNAL=$ip"

try {
  $os = Get-CimInstance Win32_OperatingSystem
  $uptime = ((Get-Date) - $os.LastBootUpTime).TotalSeconds
  Write-Output "VM_UPTIME=$([Math]::Round($uptime, 1))"
} catch { Write-Output 'VM_UPTIME=0' }

try {
  $drive = Get-PSDrive C
  $total = $drive.Used + $drive.Free
  Write-Output "DISK_TOTAL=$total"
  Write-Output "DISK_USED=$($drive.Used)"
  Write-Output "DISK_AVAIL=$($drive.Free)"
} catch {
  Write-Output 'DISK_TOTAL=0'
  Write-Output 'DISK_USED=0'
  Write-Output 'DISK_AVAIL=0'
}

try {
  $dataDir = 'C:\data\test'
  if (Test-Path $dataDir) {
    $dirSize = (Get-ChildItem $dataDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
    Write-Output "DATA_DIR_SIZE=$dirSize"
  } else { Write-Output 'DATA_DIR_SIZE=0' }
} catch { Write-Output 'DATA_DIR_SIZE=0' }

# SHA256 for log and db files
try {
  $logFile = 'C:\data\test\log.txt'
  if (Test-Path $logFile) {
    $hash = (Get-FileHash $logFile -Algorithm SHA256).Hash.ToLower()
    $sz = (Get-Item $logFile).Length
    Write-Output "LOG_FILE_SHA256=$hash"
    Write-Output "LOG_FILE_SIZE=$sz"
  } else {
    Write-Output 'LOG_FILE_SHA256=none'
    Write-Output 'LOG_FILE_SIZE=0'
  }
} catch {
  Write-Output 'LOG_FILE_SHA256=none'
  Write-Output 'LOG_FILE_SIZE=0'
}

try {
  $dbFile = 'C:\data\test\test.db'
  if (Test-Path $dbFile) {
    $hash = (Get-FileHash $dbFile -Algorithm SHA256).Hash.ToLower()
    $sz = (Get-Item $dbFile).Length
    Write-Output "DB_FILE_SHA256=$hash"
    Write-Output "DB_FILE_SIZE=$sz"
  } else {
    Write-Output 'DB_FILE_SHA256=none'
    Write-Output 'DB_FILE_SIZE=0'
  }
} catch {
  Write-Output 'DB_FILE_SHA256=none'
  Write-Output 'DB_FILE_SIZE=0'
}

# Large file — not present in Windows golden image
Write-Output 'LARGE_FILE_SIZE=0'
Write-Output 'LARGE_FILE_SHA256=none'

# Ephemeral disk — not present on Windows VMs, hardcode to trigger auto-SKIP
Write-Output 'EPHEMERAL_FILE_WRITER_LINES=0'
Write-Output 'EPHEMERAL_FILE_WRITER_SIZE=0'
Write-Output 'EPHEMERAL_FILE_WRITER_LAST=none'
Write-Output 'EPHEMERAL_FILE_WRITER_PID=none'
Write-Output 'EPHEMERAL_SQLITE_ROWS=0'
Write-Output 'EPHEMERAL_SQLITE_MAX_TS=0'
Write-Output 'EPHEMERAL_SQLITE_MIN_TS=0'
Write-Output 'EPHEMERAL_SQLITE_INTEGRITY=unknown'
Write-Output 'EPHEMERAL_SQLITE_SIZE=0'
Write-Output 'EPHEMERAL_SQLITE_PID=none'
Write-Output 'EPHEMERAL_DIR_SIZE=0'
Write-Output 'EPHEMERAL_LARGE_FILE_SIZE=0'
Write-Output 'EPHEMERAL_LARGE_FILE_SHA256=none'
PSEOF
  )

  # Append prefix SHA block if needed
  if [[ -n "$prefix_sha_block" ]]; then
    ps_script="${ps_script}
${prefix_sha_block}"
  fi

  run_on_vm_via_agent "$ps_script"
}
