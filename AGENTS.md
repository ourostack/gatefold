# Gatefold agent notes

## Delivery

- Trunk-based. Each proven change ships as its own small pull request from `main`, opened after review and validation with auto-merge on, and merges on green ([prs-merge-within-30-minutes](https://github.com/ourostack/.github/blob/main/agents/prs-merge-within-30-minutes.md)). There is no merge order: a pull request waits on another only when it can't build without it.
- No pull request stays open more than 30 minutes past green. Rebase it, fix it and merge it, or close it with a one-line reason and an issue for whatever is still worth doing.
- Don't stack fixes on a branch under review. A new finding during review is its own pull request, unless it's a defect in that pull request's own change.

## CI

- `app.yml` builds the app and its tests once (`Build for testing`, named by commit and Xcode version). Every simulator job downloads that build and runs `test-without-building`, and boots its simulator with `scripts/ci-simulator.py` while it downloads. Don't add `xcodebuild test` from source to a simulator job.
- Two tiers. Pull requests run the place, taps and unit legs in full and a smoke of the reviewers' checks. Pushes to `main` run the reviewers' full lists. A red `main` is fixed by whoever merged the change that turned it red, before their next pull request. If that agent is gone, the next agent to open a pull request here owns it.
- Every required check reports on every pull request. A check that doesn't apply skips with a job-level `if:`, which reports success, and a matrix check gets a same-named no-op job (`ipad-docs`). Never gate a required check with a workflow-level `paths` or `paths-ignore` (gatefold#42).
- A newer push to a pull request cancels its older run. Runs on `main` are never cancelled.
