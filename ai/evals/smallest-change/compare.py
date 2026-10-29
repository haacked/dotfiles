"""Prints each grader's pass rate with and without the rule, from the --json output of two single-arm eval runs.

Usage: compare.py <with.json> <without.json>
"""

import json
import sys


def pass_rates(path):
    """Returns {case: {grader: (passed runs, total runs)}} and the run's total cost."""
    result = json.load(open(path))
    rates = {}
    for case in result["cases"]:
        runs = [run for arm_runs in case["arms"].values() for run in arm_runs]
        graders = rates.setdefault(case["name"], {})
        for grader in case["graders"]:
            passed = sum(
                1 for run in runs for g in run["graders"] if g["name"] == grader["name"] and g["passed"]
            )
            graders[grader["name"]] = (passed, len(runs))
    return rates, result["costUsd"]


def main():
    with_rates, with_cost = pass_rates(sys.argv[1])
    without_rates, without_cost = pass_rates(sys.argv[2])

    print(f"{'case':<18} {'grader':<20} {'with':>6} {'without':>8}")
    for case in sorted(with_rates.keys() | without_rates.keys()):
        graders = with_rates.get(case, {}).keys() | without_rates.get(case, {}).keys()
        for grader in sorted(graders):
            cells = []
            for rates in (with_rates, without_rates):
                passed, total = rates.get(case, {}).get(grader, (0, 0))
                cells.append(f"{passed}/{total}" if total else "-")
            print(f"{case:<18} {grader:<20} {cells[0]:>6} {cells[1]:>8}")
    print(f"\ncost: with ${with_cost:.2f}, without ${without_cost:.2f}")


if __name__ == "__main__":
    main()
