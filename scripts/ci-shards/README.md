# What CI knows about each UI test

One file per UI test, `<Class>/<test>`, so two pull requests that each add a test add two files and never conflict.
`scripts/ci-shards.py check` (in `CI scripts, offline`, which the required `GatefoldCore tests` stands for) reads them all.

A test's file has:

- `tier|device` for each tier (`main`, or `pr` for a pull request's lists) and device a shard runs it in
  (gatefold#39). `python3 -I scripts/ci-shards.py write` writes these from the shards in `.github/workflows/app.yml`,
  so a test leaves CI only by a visible change here. `check --expect` fails unless they match the shards.
- `device<TAB>seconds` for its slowest pass in CI on that device, then any notes (gatefold#260). A new test needs one
  for each device it runs on: its slowest pass so far, or an estimate until CI has run it.

A shard's limit in `app.yml` is 30 min of setup, twice what its tests' slowest passes add up to, 5 for the test run's
start and stop, and 12 for the logs; `check` fails when a timeout or its comment doesn't match, and names the line to
write. "Slowest" is the 95th percentile of the test's passing or skipped times in the App runs of pull requests and
main from 42938568336 to 43280151381 (2026-11-08 to 11-12, 176 runs, runner load up to 800), so one freak run doesn't
set it; the slowest single pass is noted after it.
