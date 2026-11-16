"""Report a failed test log as one GitHub annotation and job summary.

Lists failed XCTest cases and Python tests, names the XCTest case that was
running if the test process died, and includes the end of the output.
"""
import os
import re
import sys

ANSI = re.compile(r"\x1b\[[0-9;]*m")
XCTEST_CASE = re.compile(r"^Test Case '-\[(.+?)\]' (started|passed|failed|skipped)")
PYTHON_FAILURE = re.compile(r"^(?:FAIL|ERROR): \w+ \(")
TAIL_LINES = 40
LINE_LIMIT = 300

with open(sys.argv[1], encoding="utf-8", errors="replace") as log:
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
report += ["Last output:"] + [line[:LINE_LIMIT] for line in lines[-TAIL_LINES:]]
text = "\n".join(report)

escaped = text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
print(f"::error title=Test failures::{escaped}")
if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
    with open(summary, "a", encoding="utf-8") as output:
        output.write(f"## Test failures\n\n```\n{text}\n```\n")
