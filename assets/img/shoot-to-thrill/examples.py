"""Standalone teaching examples for the public series, not game source."""
import json


def true_runs(flags):
    """Return [start, end) intervals for contiguous True values."""
    runs, start = [], None
    for index, value in enumerate([*flags, False]):
        if value and start is None:
            start = index
        elif not value and start is not None:
            runs.append((start, index))
            start = None
    return runs


def require_sequence(frame_ids, expected_count):
    """Check already-decoded IDs, not the pixels of a recording."""
    if expected_count <= 0:
        raise ValueError("A recording must contain frames")
    if frame_ids != list(range(1, expected_count + 1)):
        raise ValueError("Incomplete, reordered, or repeated frame sequence")


def compact_result(total_checks, failed_checks, detail_url):
    """A teaching example: keep the full evidence elsewhere."""
    if not 0 <= failed_checks <= total_checks:
        raise ValueError("Inconsistent check counts")
    report = {"checks": total_checks, "failed": failed_checks, "details": detail_url}
    return json.dumps(report, separators=(",", ":"))


if __name__ == "__main__":
    assert true_runs([]) == []
    assert true_runs([False, True, True, False, True]) == [(1, 3), (4, 5)]
    assert true_runs([True, True]) == [(0, 2)]
    require_sequence([1, 2, 3], 3)
    for bad in ([1, 2, 2], [1, 3], [2, 1, 3], []):
        try:
            require_sequence(bad, 3)
        except ValueError:
            pass
        else:
            raise AssertionError("Invalid sequence accepted")
    assert json.loads(compact_result(76, 6, "evidence.json"))["failed"] == 6
    print("Standalone snippet checks passed")
