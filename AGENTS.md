# Gatefold agent notes

## CI

- Pull requests follow ourostack's rule: open one only after review and validation, with auto-merge on, so it merges within 30 minutes ([prs-merge-within-30-minutes](https://github.com/ourostack/.github/blob/main/agents/prs-merge-within-30-minutes.md)).
- `app.yml` builds the app and its tests once (`Build for testing`, named by commit and Xcode version). Every simulator job downloads that build and runs `test-without-building`, and boots its simulator with `scripts/ci-simulator.py` while it downloads. Don't add `xcodebuild test` from source to a simulator job.
- UI tests run in shards of about 10 min of tests each (`.github/workflows/ui-tests.yml`, called from `app.yml`). When a shard grows past that, split it; a new test goes in a catch-all shard (one with `skip:`) unless it is long.
- Two tiers. Pull requests run the place, taps and unit legs in full and a smoke of the reviewers' checks. Pushes to `main` run the reviewers' full lists. A red `main` is fixed by whoever merged the change that turned it red, before their next pull request. If that agent is gone, the next agent to open a pull request here owns it.
- Every required check reports on every pull request. A check that doesn't apply skips with a job-level `if:`, which reports success. A sharded check (`iPad (...)`, `Duo (the reviewers' checks)`) is a gate job with `if: always()` that is green only when every shard passed, or when only Markdown changed. Never gate a required check with a workflow-level `paths` or `paths-ignore` (gatefold#42).
- A newer push to a pull request cancels its older run. Runs on `main` are never cancelled.
