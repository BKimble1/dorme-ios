"""Small portable helpers."""
import json
import os
import tempfile
from pathlib import Path


def atomic_write_json(path, data, mode=0o644):
    """temp file in the same folder, fsync, os.replace, fsync the folder where the OS allows it."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(data, handle, indent=1, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp, mode)
        os.replace(temp, path)
        if hasattr(os, "O_DIRECTORY"):
            dirfd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(dirfd)
            finally:
                os.close(dirfd)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)
