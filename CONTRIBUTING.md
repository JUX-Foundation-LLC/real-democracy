# Contributing to Real Democracy

Thank you for helping build open governance infrastructure. Please read this first — the release
model here is a little different from a typical GitHub project, and knowing how it works will save
you confusion.

## This is a mirrored-release repository

`real-democracy` is **generated from a private mono-repo**, not developed directly here. That has
two consequences you need to know about:

1. **Releases are force-pushed.** Each release regenerates `main` as a fresh snapshot. There is no
   long commit history, and the branch you forked from may be rebuilt. **Always branch from the
   latest `main` before starting work**, and expect to rebase.
2. **Your merged PR is *ported*, not merged forever.** When we accept your contribution, the change
   is applied back into the private source of truth, and the *next* release mirror includes it.
   You'll see your work in the code — it just arrives via the release snapshot rather than as a
   preserved merge commit. **We will credit you** in the release notes.

This keeps the public protocol and our private system from silently diverging: the private repo is
always the single source of truth, and this mirror is regenerated from it.

## How to contribute

1. **Open an issue first** for anything non-trivial, so we can confirm it fits before you invest
   time — and so we can port it cleanly.
2. Fork, branch from the current `main`, make your change.
3. Keep PRs **scoped and focused** — small changes port back cleanly; sprawling ones may be asked
   to be split.
4. **Never commit secrets or keys.** Generate your own validator/signer keys locally; they must
   stay out of the repo. (Our export pipeline strips key material by path, but don't rely on it —
   keep keys out.)
5. Include tests for contract changes (`smc/` uses Hardhat; see `smc/TEST_PLAN.md` where present).

## Release cadence & open PRs

Because a release force-pushes `main`, we **port or close all open PRs before cutting a release** so
your in-flight branch never has its base rebuilt underneath it mid-review. If a release lands while
your PR is open, we'll help you rebase onto the new snapshot.

## Security

Found a vulnerability? **Do not open a public issue.** Email `security@juxfoundation.com` with
details and we'll coordinate a fix and disclosure.

## License

By contributing, you agree your contributions are licensed under the project's
[AGPL-3.0](./LICENSE).
