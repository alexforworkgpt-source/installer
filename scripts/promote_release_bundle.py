"""Separate entry point for verified promotion of an existing immutable candidate."""

import argparse
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from lib.bundle_promotion_control import promote_bundle


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Verify public Bundle evidence; optionally change only prerelease/latest")
    parser.add_argument("command", choices=("verify", "promote"))
    parser.add_argument("--workspace", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    temporary = os.environ.get("RUNNER_TEMP")
    if (not temporary or not args.output.resolve().is_relative_to(Path(temporary).resolve())
            or args.output.resolve() == Path(temporary).resolve()):
        raise ValueError("promotion output must be a new child directory of RUNNER_TEMP")
    latest = os.environ["MAKE_LATEST"]
    if latest not in {"true", "false"}:
        raise ValueError("MAKE_LATEST must be an explicit true or false")
    changed = promote_bundle(
        args.workspace, args.output, os.environ["PROMOTION_EVIDENCE_SHA"],
        os.environ["PROMOTION_EVIDENCE_PATH"], os.environ["DEFAULT_BRANCH"],
        os.environ["GITHUB_REPOSITORY"], os.environ["INSTALLER_TAG"], os.environ["INSTALLER_SHA"],
        os.environ["BUNDLE_TAG"], os.environ["WORKFLOW_SHA"], latest == "true", os.environ["GH_TOKEN"],
        verify_only=args.command == "verify",
    )
    print("Exact candidate and durable evidence verified" if args.command == "verify"
          else "Bundle promoted without changing assets" if changed
          else "Bundle already stable; no metadata or assets changed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (ValueError, RuntimeError, OSError, KeyError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1) from None
