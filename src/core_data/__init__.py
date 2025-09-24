"""Core Data test harness package.

This package exists solely so the Hatch build backend can
produce an editable wheel when dependency tooling (uv, pip)
installs the project in editable mode. The actual application
logic lives in shell scripts and SQL assets under the repository
root, so we intentionally keep this module minimal.
"""

__all__: list[str] = []
