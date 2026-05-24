# Tests Module

The `tests` package verifies Core Data management behavior from the operator
boundary. Lightweight tests avoid Docker where possible, while integration tests
exercise Compose-managed services and persistent data workflows.

Tests that create temporary service data must isolate their data roots and must
not remove live directories outside their fixture-owned paths. Cleanup tests use
fake Compose binaries to validate command safety gates without depending on a
running container stack.
