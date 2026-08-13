#!/usr/bin/env python3
"""Generate a synthetic Slack JSON export without loading data into the benchmark process."""

import argparse
import json
from pathlib import Path
import zipfile


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("message_count", type=int)
    parser.add_argument("--messages-per-file", type=int, default=2_000)
    args = parser.parse_args()
    if args.message_count < 1:
        parser.error("message_count must be positive")
    if args.messages_per_file < 1:
        parser.error("messages-per-file must be positive")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.output.exists():
        parser.error(f"output already exists: {args.output}")

    per_file = args.messages_per_file
    with zipfile.ZipFile(args.output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        archive.writestr("users.json", '[{"id":"U-PERF","profile":{"real_name":"Performance Custodian"}}]')
        archive.writestr("channels.json", '[{"id":"C-PERF","name":"performance"}]')
        for file_index, lower in enumerate(range(0, args.message_count, per_file)):
            rows = []
            for index in range(lower, min(lower + per_file, args.message_count)):
                marker = " needle" if index % 25_000 == 0 else ""
                rows.append({
                    "user": "U-PERF",
                    "text": f"performance message {index}{marker}",
                    "ts": f"{1_700_000_000 + index / 1_000:.6f}",
                })
            archive.writestr(
                "performance/"
                f"{2020 + file_index // (12 * 28):04d}-"
                f"{(file_index // 28) % 12 + 1:02d}-"
                f"{file_index % 28 + 1:02d}.json",
                json.dumps(rows, separators=(",", ":")),
            )

    print(args.output)


if __name__ == "__main__":
    main()
