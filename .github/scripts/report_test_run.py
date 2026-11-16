"""Report a CI test run as GitHub annotations and a job summary.

usage: report_test_run.py OUTCOME TEST_LOG MEMORY_LOG

A successful run gets one notice with its peak memory use. A failed run gets
one error listing failed XCTest cases and Python tests, the XCTest case that
was running if the test process died, the macOS crash reports and kernel
memory kills recorded during the run, memory samples and the end of the
output.
"""
import glob
import json
import os
import re
import subprocess
import sys
import time

ANSI = re.compile(r"\x1b\[[0-9;]*m")
XCTEST_CASE = re.compile(r"^Test Case '-\[(.+?)\]' (started|passed|failed|skipped)")
PYTHON_FAILURE = re.compile(r"^(?:FAIL|ERROR): \w+ \(")
SAMPLE_FIELD = re.compile(r"(\w+)=(-?\d+)")
CRASH_REPORTS = os.path.expanduser("~/Library/Logs/DiagnosticReports")
CRASH_FRAMES = 30
MEMORY_LINES = 12
KERNEL_LINES = 30
TAIL_LINES = 40
LINE_LIMIT = 300


def annotate(level, title, text):
    escaped = text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print(f"::{level} title={title}::{escaped}")
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a", encoding="utf-8") as output:
            output.write(f"## {title}\n\n```\n{text}\n```\n")


def read_lines(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as log:
            return [ANSI.sub("", line.rstrip("\r\n")) for line in log]
    except OSError:
        return []


def memory_peaks(samples):
    values = [dict((key, int(value)) for key, value in SAMPLE_FIELD.findall(line)) for line in samples]
    values = [value for value in values if value]
    if not values:
        return "No memory samples."
    def most(key):
        return max(value.get(key, 0) for value in values)
    def least(key):
        return min(value.get(key, 0) for value in values)
    return (f"Peak xctest {most('xctest_mb')} MB, Python {most('python_mb')} MB, "
            f"compressor {most('compressor_mb')} MB, swap {most('swap_used_mb')} MB; "
            f"lowest free memory {least('free_pct')}%, disk {least('disk_free_mb')} MB "
            f"({len(values)} samples)")


def crash_reports(since):
    # ReportCrash writes a report shortly after the process ends.
    deadline = time.monotonic() + 30
    while True:
        reports = sorted((path for path in glob.glob(f"{CRASH_REPORTS}/*.ips") if os.path.getmtime(path) >= since),
                         key=os.path.getmtime)
        if reports or time.monotonic() > deadline:
            return reports[:3]
        time.sleep(2)


def describe_crash(path):
    lines = [f"Crash report {os.path.basename(path)}:"]
    try:
        with open(path, encoding="utf-8", errors="replace") as report:
            report.readline()
            body = json.load(report)
        exception, termination = body.get("exception", {}), body.get("termination", {})
        lines.append(f"  {exception.get('type')} {exception.get('signal')} ({termination.get('indicator')})")
        for image, messages in (body.get("asi") or {}).items():
            lines += [f"  {image}: {message}" for message in messages]
        thread = body["threads"][body.get("faultingThread", 0)]
        lines.append(f"  Crashed thread queue: {thread.get('queue', 'none')}")
        images = body.get("usedImages", [])
        for frame in thread["frames"][:CRASH_FRAMES]:
            index = frame.get("imageIndex", -1)
            image = images[index].get("name", "?") if 0 <= index < len(images) else "?"
            symbol = frame.get("symbol", hex(frame.get("imageOffset", 0)))
            source = ":".join(str(part) for part in (frame.get("sourceFile"), frame.get("sourceLine")) if part)
            source = f" ({source})" if source else ""
            lines.append(f"    {image} {symbol}{source}")
    except (OSError, ValueError, KeyError, IndexError, TypeError) as error:
        lines.append(f"  Unreadable: {error}")
    return lines


def kernel_memory_events(since):
    # A process killed for memory gets SIGKILL, which leaves no crash report.
    start = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(since))
    predicate = ('process == "kernel" AND (eventMessage CONTAINS "memorystatus" '
                 'OR eventMessage CONTAINS[c] "swap" OR eventMessage CONTAINS "xctest")')
    try:
        result = subprocess.run(["/usr/bin/log", "show", "--start", start, "--style", "compact",
                                 "--predicate", predicate], capture_output=True, text=True, timeout=120)
        events = [line for line in result.stdout.splitlines()[1:] if line.strip()]
    except (OSError, subprocess.SubprocessError) as error:
        return [f"  Unavailable: {error}"]
    return [f"  {line}" for line in events[-KERNEL_LINES:]] or ["  None"]


outcome, log_path, memory_path = sys.argv[1:4]
samples = read_lines(memory_path)
if outcome == "success":
    annotate("notice", "Test memory", memory_peaks(samples))
    sys.exit(0)

lines = read_lines(log_path)
failed, running = [], None
for line in lines:
    if match := XCTEST_CASE.match(line):
        name, state = match.groups()
        running = name if state == "started" else None
        if state == "failed" and name not in failed:
            failed.append(name)
failed += [line for line in lines if PYTHON_FAILURE.match(line)]

report = []
if failed:
    report += ["Failed tests:"] + [f"  {name}" for name in failed]
if running:
    since = os.stat(log_path).st_birthtime
    report.append(f"Test process ended while running: {running}")
    for path in crash_reports(since):
        report += describe_crash(path)
    report += ["Kernel memory events:"] + kernel_memory_events(since)
report += ["Memory: " + memory_peaks(samples)] + [f"  {line}" for line in samples[-MEMORY_LINES:]]
report += ["Last output:"] + lines[-TAIL_LINES:]
annotate("error", "Test failures", "\n".join(line[:LINE_LIMIT] for line in report))
