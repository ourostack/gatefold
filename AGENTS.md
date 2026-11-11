# Gatefold agent notes

## CI

- Pull requests follow ourostack's rule: open one only after review and validation, with auto-merge on, so it merges as fast as possible; 30 minutes is the outer alarm, not the goal ([shared rule](https://github.com/ourostack/.github/blob/main/agents/prs-merge-within-30-minutes.md)).
- `app.yml` builds the app and its tests once (`Build for testing`, named by commit and Xcode version). Every simulator job downloads that build and runs `test-without-building`, and boots its simulator with `scripts/ci-simulator.py` while it downloads. Don't add `xcodebuild test` from source to a simulator job.
- Two tiers. Pull requests run the place, taps and unit legs in full and a smoke of the reviewers' checks. Pushes to `main` run the reviewers' full lists. A red `main` is fixed by whoever merged the change that turned it red, before their next pull request. If that agent is gone, the next agent to open a pull request here owns it.
- Every required check reports on every pull request. A check that doesn't apply skips with a job-level `if:`, which reports success, and a matrix check gets a same-named no-op job (`ipad-docs`). Never gate a required check with a workflow-level `paths` or `paths-ignore` (gatefold#42).
- A newer push to a pull request cancels its older run. Runs on `main` are never cancelled.
