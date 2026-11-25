"""Locate the existing, tested `dorme` package (dorme_robot/dorme) and import its frame codec.

The coordinator wraps that code; it never copies or edits it. Search order:
1. DORME_ROBOT_LIB environment variable (folder that contains the `dorme` package)
2. /opt/dorme/lib (where dorme_robot/install.sh puts it on the Pi)
3. ../../dorme_robot relative to this repository (development checkout)
"""
import os
import sys
from pathlib import Path

_HERE = Path(__file__).resolve()
_CANDIDATES = [os.environ.get("DORME_ROBOT_LIB"), "/opt/dorme/lib",
               str(_HERE.parents[3] / "dorme_robot")]

for _candidate in _CANDIDATES:
    if _candidate and (Path(_candidate) / "dorme" / "protocol.py").is_file():
        if _candidate not in sys.path:
            sys.path.insert(0, _candidate)
        LEGACY_PATH = _candidate
        break
else:  # pragma: no cover - only when the repository is incomplete
    raise ImportError("Cannot find dorme_robot/dorme/protocol.py; set DORME_ROBOT_LIB")

from dorme import protocol  # noqa: E402  (the unmodified, tested codec)

__all__ = ["protocol", "LEGACY_PATH"]
