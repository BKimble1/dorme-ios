"""DORM-E coordinator: the single command path for the app, BLE, tasks and local tools.

Wraps the existing, tested Pi code in dorme_robot/ (frame codec, dorme-linkd) without changing it.
"""
from .api import API_VERSION, SOFTWARE_VERSION  # noqa: F401
