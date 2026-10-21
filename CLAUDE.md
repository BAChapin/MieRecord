# MieRecord

Offline-first iOS conversation recorder. `SPEC.md` is the product source of truth; `IMPLEMENTATION_PLAN.md` tracks milestones, decisions, verification, and known limitations.

## Commits

- Commit as you go. Each logical unit of work (a feature, a fix, a refactor, a docs update) gets its own commit once it builds and its tests pass. Do not let finished work accumulate uncommitted.
- Keep commits coherent and reviewable on their own. Separate unrelated concerns (for example an engine change and an unrelated UI fix) into separate commits; keep tightly coupled changes together.
- Use the `commit` skill's message format: descriptive title, then a structured body listing every changed file with `+` / `-` / `~`. Non-code commits (docs, config, assets) use a title line only.
- Stage files by name, never `git add -A` or `git add .`.
- Update `IMPLEMENTATION_PLAN.md` in the same commit as the work it describes, or in a docs commit right after.
- Do not push unless asked.

## Build and test

```bash
cd ConversationKit && swift test
```

```bash
xcodebuild -project MieRecord.xcodeproj -scheme MieRecord -destination 'generic/platform=iOS' build
```

# CI Practices: MieRecord

## Pipeline (GitHub Actions)

- **On every push to `main`:** run linting, build, and unit tests.
- **On tag creation:**
  1. Verify the current head of `main` has passing CI results. If it doesn't, stop.
  2. Run UI and integration tests.
  3. Create the release only if those pass.
- Test locally before pushing whenever practical.

## Branching: Ship / Show / Ask

- When starting a body of work or a feature, ask me which mode fits before implementing:
  - **Ship:** change is small, low-risk, and well-covered by tests. Merge directly once CI passes.
  - **Show:** change is worth reviewing but can merge without waiting. Open a PR, let CI run, and merge once it's green, and tell me what to look at.
  - **Ask:** change is risky, unclear, or needs a decision from me. Open a PR and wait for my approval before merging.
- If the work fits Ship, say so in the question.

## Fixing CI Failures

- If something gets past local testing and breaks CI on `main`, create a fix branch and open a Show PR.
- Merge the fix into `main` only after the full suite passes.
- Never disable, skip, or delete a failing test to get a green build. Fix the cause, or ask me first.

## Secrets

- The repository is public. Never commit secrets, API keys, signing certificates, or provisioning profiles.
- Store all credentials in GitHub Actions encrypted secrets and reference them by name.
- If a secret appears in code, config, or logs, stop and tell me.

## Deployment

- No automated deployment for now. Release builds stop at a verified artifact.
- CD to App Store Connect will be defined in a later update to this file.
