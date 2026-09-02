"""Turn the driver's marks into offsets into the footage.

`Demo.swift` writes the epoch time of each thing it did; `demo.sh` knows the
epoch time the recording began. Neither knows the other's, so the subtraction
happens here, once, and what lands on disk is what the edit actually wants:
seconds from the first frame.

    python3 marketing/video/beats.py <beats.json> <started at> [notified at]

The optional third argument is when the notification was delivered. It comes
from the script rather than the driver, because the driver is not running yet
when it happens — the whole point of that beat is that the app is closed.
"""

import json
import sys


def main() -> None:
    path, started = sys.argv[1], float(sys.argv[2])
    with open(path, encoding="utf-8") as handle:
        marks = json.load(handle)
    if len(sys.argv) > 3 and sys.argv[3]:
        marks["notified"] = float(sys.argv[3])
    # Sorted by when they happened, not by name: read top to bottom, the file
    # is the running order.
    offsets = {
        name: round(at - started, 2)
        for name, at in sorted(marks.items(), key=lambda pair: pair[1])
    }
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(offsets, handle, indent=2)
        handle.write("\n")


if __name__ == "__main__":
    main()
