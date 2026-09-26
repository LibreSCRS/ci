# LibreSCRS/ci

Shared CI gates, release steps and packaging actions for the LibreSCRS
repositories. One source instead of a copy per repository: each consumer
references an action here by commit SHA in its workflow, and nothing else.

- `scripts/` — the gate scripts and their self-tests. Every self-test ends with
  `selftest: <n> cases, <r> red-proved`; `scripts/run-selftests.sh` runs them.
- `actions/` — composite actions the consumers call (`gates`, `checkout-deps`,
  `release-preflight`, `release-seal`, `release-publish`, `pkg-build`,
  `pkg-verify`).
- `actions/gates` — runs the gates its `gates:` input names (see the action for
  the list); an empty list or an unknown name is "cannot judge" (exit 2).
- `images.lock` — container images by digest and packaging tools by version and
  checksum.

Exit codes are uniform: `0` judged and passed, `1` judged and failed, `2` could
not judge. A consumer tests `rc = 0`, never "not 1".

Licensed under LGPL-2.1-or-later (see `LICENSE`).
