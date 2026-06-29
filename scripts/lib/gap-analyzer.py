#!/usr/bin/env python3
"""
Analyze time gaps in log file entries.

Reads log lines from stdin, extracts timestamps using a regex pattern,
and reports gaps that exceed the expected interval.

Modes:
  windows - Bucket gaps into 30s time windows (for file-writer analysis)
  gaps    - Report individual gaps exceeding threshold (for cron analysis)

Usage:
  cat /data/test/log.txt | python3 gap-analyzer.py \
    --pattern '(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})' \
    --format '%Y-%m-%dT%H:%M:%S' \
    --expected-interval 1 \
    --mode windows

  cat /data/test/cron.log | python3 gap-analyzer.py \
    --pattern 'at (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})' \
    --format '%Y-%m-%dT%H:%M:%S' \
    --expected-interval 60 \
    --mode gaps
"""
import sys
import json
import re
import argparse
from datetime import datetime, timezone


def parse_entries(lines, pattern, fmt):
    regex = re.compile(pattern)
    entries = []
    for line in lines:
        m = regex.search(line)
        if m:
            try:
                dt = datetime.strptime(m.group(1), fmt)
                entries.append(int(dt.replace(tzinfo=timezone.utc).timestamp()))
            except (ValueError, IndexError):
                continue
    return entries


def analyze_windows(entries, expected_interval, bucket_size=30):
    if len(entries) < 2:
        return []

    buckets = {}
    for i in range(1, len(entries)):
        gap = entries[i] - entries[i - 1]
        bucket_ts = (entries[i] // bucket_size) * bucket_size

        if bucket_ts not in buckets:
            buckets[bucket_ts] = {"total": 0, "slow": 0, "max_gap": 0}

        buckets[bucket_ts]["total"] += 1
        if gap > expected_interval:
            buckets[bucket_ts]["slow"] += 1
        if gap > buckets[bucket_ts]["max_gap"]:
            buckets[bucket_ts]["max_gap"] = gap

    result = []
    for bucket_ts in sorted(buckets.keys()):
        b = buckets[bucket_ts]
        if b["slow"] > 0:
            slow_pct = round(b["slow"] * 100.0 / b["total"], 1) if b["total"] > 0 else 0
            status = "affected" if b["slow"] >= 5 else "jitter"
            result.append({
                "time_window_utc": datetime.utcfromtimestamp(bucket_ts).strftime("%Y-%m-%d %H:%M:%S"),
                "epoch": bucket_ts,
                "total_writes": b["total"],
                "slow_writes": b["slow"],
                "slow_pct": slow_pct,
                "max_gap_sec": b["max_gap"],
                "status": status,
            })
    return result


def analyze_gaps(entries, expected_interval):
    if len(entries) < 2:
        return []

    gaps = []
    for i in range(1, len(entries)):
        gap = entries[i] - entries[i - 1]
        if gap > expected_interval:
            gaps.append({
                "from_time_utc": datetime.utcfromtimestamp(entries[i - 1]).strftime("%Y-%m-%d %H:%M:%S"),
                "to_time_utc": datetime.utcfromtimestamp(entries[i]).strftime("%Y-%m-%d %H:%M:%S"),
                "gap_seconds": gap,
                "missing_executions": max(0, (gap // expected_interval) - 1),
            })
    return gaps


def main():
    parser = argparse.ArgumentParser(description="Analyze time gaps in log entries")
    parser.add_argument("--pattern", required=True,
                        help="Regex with one capturing group for the timestamp")
    parser.add_argument("--format", required=True,
                        help="strptime format string for the captured timestamp")
    parser.add_argument("--expected-interval", type=int, default=1,
                        help="Expected seconds between entries (default: 1)")
    parser.add_argument("--mode", choices=["windows", "gaps"], default="windows",
                        help="Analysis mode: windows (30s buckets) or gaps (individual)")
    args = parser.parse_args()

    try:
        lines = sys.stdin.readlines()
        entries = parse_entries(lines, args.pattern, args.format)

        if args.mode == "windows":
            result = analyze_windows(entries, args.expected_interval)
        else:
            result = analyze_gaps(entries, args.expected_interval)

        print(json.dumps(result))
    except Exception:
        print("[]")


if __name__ == "__main__":
    main()
