<!-- SPDX-License-Identifier: LGPL-2.1-or-later -->
# lint-accepted

One file per package, `<package>.txt`, read by `scripts/pkg-lint-accept.py`
after `scripts/pkg-verify.sh` runs lintian / rpmlint in the slug's container.

    <lintian|rpmlint> <slug-glob> <tag> <context-glob> -- <reason>

- Every lintian / rpmlint error and warning must match a row, or the stack is red.
- At most 5 rows per package; every row has a reason.
- A tag outside the `embedded-library` family (the bundling policy of
  `README-bundling.md`) also names who decided it: `[owner YYYY-MM-DD]` (an
  owner decision, e.g. SPEC D18) or `[session YYYY-MM-DD]` (a working-session
  decision recorded in the plan and awaiting the owner's review).
- The cap is per package, not per slug: one row covers every slug its glob
  matches, and openSUSE's archive policy fits in it (4 rows for
  `librescrs-middleware`).
- A row that applies to the run and matches nothing is red: delete it.
