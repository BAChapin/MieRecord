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
