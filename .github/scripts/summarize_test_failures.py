"""Report a failed test log as one GitHub annotation and job summary.

Lists failed XCTest cases and Python tests, names the XCTest case that was
running if the test process died, adds the macOS crash reports written
during the run, and includes the end of the output.
"""
import glob
import json
import os
import re
import sys
import time

ANSI = re.compile(r"\x1b\[[0-9;]*m")
XCTEST_CASE = re.compile(r"^Test Case '-\[(.+?)\]' (started|passed|failed|skipped)")
PYTHON_FAILURE = re.compile(r"^(?:FAIL|ERROR): \w+ \(")
CRASH_REPORTS = os.path.expanduser("~/Library/Logs/DiagnosticReports")
CRASH_FRAMES = 30
TAIL_LINES = 40
LINE_LIMIT = 300


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


log_path = sys.argv[1]
with open(log_path, encoding="utf-8", errors="replace") as log:
    lines = [ANSI.sub("", line.rstrip("\r\n")) for line in log]

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
    report.append(f"Test process ended while running: {running}")
    for path in crash_reports(os.stat(log_path).st_birthtime):
        report += describe_crash(path)
report += ["Last output:"] + lines[-TAIL_LINES:]
text = "\n".join(line[:LINE_LIMIT] for line in report)

escaped = text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
print(f"::error title=Test failures::{escaped}")
if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
    with open(summary, "a", encoding="utf-8") as output:
        output.write(f"## Test failures\n\n```\n{text}\n```\n")
