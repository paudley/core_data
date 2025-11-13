#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

"""Compare two floating-point numbers using basic relational operators."""

from __future__ import annotations

import argparse
import sys

OPERATORS = {
    "lt": lambda a, b: a < b,
    "le": lambda a, b: a <= b,
    "gt": lambda a, b: a > b,
    "ge": lambda a, b: a >= b,
}


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--lt", action="store_true", help="Return success when lhs < rhs")
    group.add_argument("--le", action="store_true", help="Return success when lhs <= rhs (default)")
    group.add_argument("--gt", action="store_true", help="Return success when lhs > rhs")
    group.add_argument("--ge", action="store_true", help="Return success when lhs >= rhs")
    parser.add_argument("lhs", help="Left-hand-side value")
    parser.add_argument("rhs", help="Right-hand-side value")
    return parser.parse_args(argv)


def select_operator(args: argparse.Namespace):
    if args.lt:
        return OPERATORS["lt"], "lt"
    if args.gt:
        return OPERATORS["gt"], "gt"
    if args.ge:
        return OPERATORS["ge"], "ge"
    return OPERATORS["le"], "le"


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    op_func, _ = select_operator(args)
    try:
        lhs = float(args.lhs)
        rhs = float(args.rhs)
    except ValueError:
        return 2
    return 0 if op_func(lhs, rhs) else 1


if __name__ == "__main__":  # pragma: no cover - exercised via callers
    sys.exit(main(sys.argv[1:]))
