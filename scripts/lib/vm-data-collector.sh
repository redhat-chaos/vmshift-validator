#!/usr/bin/env bash
# scripts/lib/vm-data-collector.sh — Shared VM workload data collection via virtctl ssh.
#
# Requires lib/ssh.sh (run_on_vm) to be sourced first.
#
# Usage:
#   VM_DATA=$(collect_vm_data [pre_log_size] [pre_db_size])
#
# Optional args enable prefix SHA256 validation in the same SSH session (post-migration).

[[ -n "${_VM_DATA_COLLECTOR_LOADED:-}" ]] && return 0
_VM_DATA_COLLECTOR_LOADED=1

collect_vm_data() {
  local pre_log_size="${1:-0}"
  local pre_db_size="${2:-0}"
  local prefix_sha_cmds=""

  if [[ "$pre_log_size" =~ ^[0-9]+$ ]] && [[ "$pre_log_size" -gt 0 ]]; then
    prefix_sha_cmds="${prefix_sha_cmds}
echo \"PREFIX_LOG_SHA=\$(head -c ${pre_log_size} /data/test/log.txt 2>/dev/null | sha256sum | cut -d' ' -f1 || echo none)\""
  fi

  if [[ "$pre_db_size" =~ ^[0-9]+$ ]] && [[ "$pre_db_size" -gt 0 ]]; then
    prefix_sha_cmds="${prefix_sha_cmds}
echo \"PREFIX_DB_SHA=\$(head -c ${pre_db_size} /data/test.db 2>/dev/null | sha256sum | cut -d' ' -f1 || echo none)\""
  fi

  run_on_vm "
echo \"CAPTURE_TIME_UTC=\$(date -u '+%Y-%m-%dT%H:%M:%S UTC')\"
echo \"CAPTURE_TIME_LOCAL=\$(date '+%Y-%m-%d %H:%M:%S %Z')\"

echo \"FILE_WRITER_LINES=\$(wc -l < /data/test/log.txt 2>/dev/null || echo 0)\"
echo \"FILE_WRITER_SIZE=\$(du -b /data/test/log.txt 2>/dev/null | cut -f1 || echo 0)\"
echo \"FILE_WRITER_LAST=\$(tail -1 /data/test/log.txt 2>/dev/null || echo none)\"
echo \"FILE_WRITER_PID=\$(systemctl show -p MainPID file-writer.service 2>/dev/null | cut -d= -f2 || echo none)\"

python3 -c '
import sqlite3
try:
    c = sqlite3.connect(\"/data/test.db\")
    rows = c.execute(\"SELECT count(*) FROM test\").fetchone()[0]
    max_ts = c.execute(\"SELECT max(timestamp) FROM test\").fetchone()[0] or 0
    min_ts = c.execute(\"SELECT min(timestamp) FROM test\").fetchone()[0] or 0
    integrity = c.execute(\"PRAGMA integrity_check\").fetchone()[0]
    all_ts = [r[0] for r in c.execute(\"SELECT timestamp FROM test ORDER BY rowid\").fetchall()]
    gaps = [all_ts[i] - all_ts[i-1] for i in range(1, len(all_ts))]
    gaps_gt2 = sum(1 for g in gaps if g > 2)
    max_gap = max(gaps) if gaps else 0
    print(f\"SQLITE_ROWS={rows}\")
    print(f\"SQLITE_MAX_TS={max_ts}\")
    print(f\"SQLITE_MIN_TS={min_ts}\")
    print(f\"SQLITE_INTEGRITY={integrity}\")
    print(f\"SQLITE_GAPS_GT2={gaps_gt2}\")
    print(f\"SQLITE_MAX_GAP={max_gap}\")
except Exception:
    print(\"SQLITE_ROWS=0\")
    print(\"SQLITE_MAX_TS=0\")
    print(\"SQLITE_MIN_TS=0\")
    print(\"SQLITE_INTEGRITY=unknown\")
    print(\"SQLITE_GAPS_GT2=-1\")
    print(\"SQLITE_MAX_GAP=-1\")
' 2>/dev/null || { echo \"SQLITE_ROWS=0\"; echo \"SQLITE_MAX_TS=0\"; echo \"SQLITE_MIN_TS=0\"; echo \"SQLITE_INTEGRITY=unknown\"; echo \"SQLITE_GAPS_GT2=-1\"; echo \"SQLITE_MAX_GAP=-1\"; }
echo \"SQLITE_SIZE=\$(du -b /data/test.db 2>/dev/null | cut -f1 || echo 0)\"
echo \"SQLITE_PID=\$(systemctl show -p MainPID sqlite-writer.service 2>/dev/null | cut -d= -f2 || echo none)\"

echo \"CRON_LINES=\$(wc -l < /data/test/cron.log 2>/dev/null || echo 0)\"
echo \"CRON_LAST=\$(tail -1 /data/test/cron.log 2>/dev/null || echo none)\"
echo \"CROND_STATUS=\$(systemctl is-active crond 2>/dev/null || echo inactive)\"
echo \"CRONTAB_ENTRY=\$(crontab -l 2>/dev/null | head -1 || echo none)\"

echo \"HTTP_STATUS=\$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080 2>/dev/null | tr -dc '0-9' || echo 0)\"
echo \"HTTP_PID=\$(systemctl show -p MainPID http-server.service 2>/dev/null | cut -d= -f2 || echo none)\"

echo \"VM_HOSTNAME=\$(hostname)\"
echo \"VM_IP_INTERNAL=\$(ip -4 addr show | grep 'inet ' | grep -v 127.0.0 | sed 's/.*inet //' | cut -d' ' -f1 | head -1)\"
echo \"VM_UPTIME=\$(cut -d' ' -f1 /proc/uptime)\"
echo \"DISK_TOTAL=\$(df -B1 / | tail -1 | tr -s ' ' | cut -d' ' -f2)\"
echo \"DISK_USED=\$(df -B1 / | tail -1 | tr -s ' ' | cut -d' ' -f3)\"
echo \"DISK_AVAIL=\$(df -B1 / | tail -1 | tr -s ' ' | cut -d' ' -f4)\"
echo \"DATA_DIR_SIZE=\$(du -sb /data/test/ 2>/dev/null | cut -f1 || echo 0)\"

echo \"LOG_FILE_SHA256=\$(sha256sum /data/test/log.txt 2>/dev/null | cut -d' ' -f1 || echo none)\"
echo \"LOG_FILE_SIZE=\$(stat -c%s /data/test/log.txt 2>/dev/null || echo 0)\"
echo \"DB_FILE_SHA256=\$(sha256sum /data/test.db 2>/dev/null | cut -d' ' -f1 || echo none)\"
echo \"DB_FILE_SIZE=\$(stat -c%s /data/test.db 2>/dev/null || echo 0)\"
echo \"LARGE_FILE_SIZE=\$(stat -c%s /data/large-file.bin 2>/dev/null || echo 0)\"
echo \"LARGE_FILE_SHA256=\$(sha256sum /data/large-file.bin 2>/dev/null | cut -d' ' -f1 || echo none)\"

echo \"EPHEMERAL_FILE_WRITER_LINES=\$(wc -l < /var/lib/test-ephemeral/log.txt 2>/dev/null || echo 0)\"
echo \"EPHEMERAL_FILE_WRITER_SIZE=\$(du -b /var/lib/test-ephemeral/log.txt 2>/dev/null | cut -f1 || echo 0)\"
echo \"EPHEMERAL_FILE_WRITER_LAST=\$(tail -1 /var/lib/test-ephemeral/log.txt 2>/dev/null || echo none)\"
echo \"EPHEMERAL_FILE_WRITER_PID=\$(pgrep -f 'test-ephemeral/log.txt' -o 2>/dev/null || echo none)\"

python3 -c '
import sqlite3
try:
    c = sqlite3.connect(\"/var/lib/test-ephemeral/test.db\")
    rows = c.execute(\"SELECT count(*) FROM test\").fetchone()[0]
    max_ts = c.execute(\"SELECT max(timestamp) FROM test\").fetchone()[0] or 0
    min_ts = c.execute(\"SELECT min(timestamp) FROM test\").fetchone()[0] or 0
    integrity = c.execute(\"PRAGMA integrity_check\").fetchone()[0]
    print(f\"EPHEMERAL_SQLITE_ROWS={rows}\")
    print(f\"EPHEMERAL_SQLITE_MAX_TS={max_ts}\")
    print(f\"EPHEMERAL_SQLITE_MIN_TS={min_ts}\")
    print(f\"EPHEMERAL_SQLITE_INTEGRITY={integrity}\")
except Exception:
    print(\"EPHEMERAL_SQLITE_ROWS=0\")
    print(\"EPHEMERAL_SQLITE_MAX_TS=0\")
    print(\"EPHEMERAL_SQLITE_MIN_TS=0\")
    print(\"EPHEMERAL_SQLITE_INTEGRITY=unknown\")
' 2>/dev/null || { echo \"EPHEMERAL_SQLITE_ROWS=0\"; echo \"EPHEMERAL_SQLITE_MAX_TS=0\"; echo \"EPHEMERAL_SQLITE_MIN_TS=0\"; echo \"EPHEMERAL_SQLITE_INTEGRITY=unknown\"; }
echo \"EPHEMERAL_SQLITE_SIZE=\$(du -b /var/lib/test-ephemeral/test.db 2>/dev/null | cut -f1 || echo 0)\"
echo \"EPHEMERAL_SQLITE_PID=\$(pgrep -f 'sqlite-writer-ephemeral' -o 2>/dev/null || echo none)\"

echo \"EPHEMERAL_DIR_SIZE=\$(du -sb /var/lib/test-ephemeral/ 2>/dev/null | cut -f1 || echo 0)\"
echo \"EPHEMERAL_LARGE_FILE_SIZE=\$(stat -c%s /var/lib/test-ephemeral/large-file.bin 2>/dev/null || echo 0)\"
echo \"EPHEMERAL_LARGE_FILE_SHA256=\$(sha256sum /var/lib/test-ephemeral/large-file.bin 2>/dev/null | cut -d' ' -f1 || echo none)\"
${prefix_sha_cmds}
"
}

# Extract a delimited section from multi-part SSH output (gap analysis bundle).
extract_gap_section() {
  local raw="$1"
  local start_marker="$2"
  local end_marker="$3"
  echo "$raw" | sed -n "/^${start_marker}\$/,/^${end_marker}\$/{ /^___/d; p; }"
}
