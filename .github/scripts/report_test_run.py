"""Report a CI test run as GitHub annotations and a job summary.

usage: report_test_run.py OUTCOME TEST_LOG MEMORY_LOG

A successful run gets one notice with its peak memory use. A failed run gets
one error listing failed XCTest cases and Python tests, the XCTest case that
was running if the test process died, the crash reports, new diagnostic
reports and relevant system log lines from around its end, memory samples
and the end of the output. The complete system log window goes to the job
log.
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
SYSTEM_LOG_BEFORE = 60
SYSTEM_LOG_AFTER = 5
SYSTEM_LOG_LINES = 40
SYSTEM_LOG_PREDICATE = ('process == "kernel" OR process == "launchd" OR process == "runningboardd" '
                        'OR process == "WindowServer" OR eventMessage CONTAINS "xctest" '
                        'OR (process == "xctest" AND (messageType == error OR messageType == fault))')
SYSTEM_LOG_KEYWORDS = re.compile(r"\b(kill|terminat|signal|sigkill|sigterm|jetsam|memorystatus|gpu|hang|timeout"
                                 r"|abort|crash|exit|resource)", re.IGNORECASE)
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


def system_events(ended):
    # A SIGKILLed process leaves no crash report and SwiftPM prints no signal,
    # so look for whatever ended it in the system log. The complete window
    # goes to the job log; the annotation keeps the lines that look relevant.
    def local(timestamp):
        return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(timestamp))
    try:
        result = subprocess.run(["/usr/bin/log", "show", "--start", local(ended - SYSTEM_LOG_BEFORE),
                                 "--end", local(ended + SYSTEM_LOG_AFTER), "--style", "compact",
                                 "--predicate", SYSTEM_LOG_PREDICATE], capture_output=True, text=True, timeout=180)
        events = [line for line in result.stdout.splitlines()[1:] if line.strip()]
    except (OSError, subprocess.SubprocessError) as error:
        return [f"  Unavailable: {error}"]
    print("::group::System log around the end of the test process")
    print("\n".join(events))
    print("::endgroup::")
    def relevant(line):
        # Compact lines are: date time type process[pid:tid] message.
        fields = line.split(None, 4)
        mentions_xctest = len(fields) == 5 and not fields[3].startswith("xctest[") and "xctest" in fields[4]
        return mentions_xctest or SYSTEM_LOG_KEYWORDS.search(line)
    selected = [f"  {line}" for line in events if relevant(line)]
    return selected[-SYSTEM_LOG_LINES:] or [f"  Nothing relevant in {len(events)} lines"]


def new_diagnostic_reports(since):
    paths = glob.glob(f"{CRASH_REPORTS}/**/*", recursive=True)
    paths += glob.glob("/Library/Logs/DiagnosticReports/**/*", recursive=True)
    names = sorted(os.path.basename(path) for path in paths if os.path.isfile(path) and os.path.getmtime(path) >= since)
    return [f"  {name}" for name in names] or ["  None"]


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
    report += ["New diagnostic reports:"] + new_diagnostic_reports(since)
    report += ["System log around the end:"] + system_events(os.stat(log_path).st_mtime)
report += ["Memory: " + memory_peaks(samples)] + [f"  {line}" for line in samples[-MEMORY_LINES:]]
report += ["Last output:"] + lines[-TAIL_LINES:]
annotate("error", "Test failures", "\n".join(line[:LINE_LIMIT] for line in report))
