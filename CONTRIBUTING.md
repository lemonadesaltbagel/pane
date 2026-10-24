# Contributing to pane

Thank you for helping. A few rules keep pane's code clean and its licence clear.

## The CLA

Before your first pull request is merged, sign the contributor licence agreement in `CLA.md` (the CLA bot on your
pull request asks you to). You keep the copyright in your work. You give pane's author a licence to use it in pane
under the AGPL, and also in the official build, which is sold under a different licence. Without that, pane couldn't
take outside contributions at all.

## Write the code yourself

pane re-implements techniques and does not copy code from other projects. Many macOS window managers are GPL, and some
have no licence at all. If you learned how to do something from another project, write it in your own words and say
where the idea came from in the pull request.

- **The audit:** `scripts/code-origin.py` compares pane's code with other projects (see the script for how to point it
  at their checkouts).
- **MIT code:** small pieces may be used with credit in `NOTICE`. Ask first.

## Before a pull request

- `swift build` and `scripts/test.sh --unit` pass.
- If you touched behaviour, the integration tests for it pass (`scripts/test.sh --filter <suite>`). They take over the
  screen while they run.
- `scripts/check-free-build.sh` passes. The engine must not depend on anything outside this repository.
- **Comments:** short, plain English, saying why rather than what. Match the code around yours.

## Reporting a bug

- **What to include:** your macOS version, what you did, what you expected and what happened.
- **The log:** turn on Settings ▸ Advanced ▸ *Write a diagnostic log* and attach `~/Library/Logs/Pane/pane.log` (look
  through it first: it names your apps and windows).
