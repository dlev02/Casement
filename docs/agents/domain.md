# Domain Docs

How the engineering skills should consume Casement's domain documentation when exploring the codebase.

## Before exploring, read these

- **`GLOSSARY.md`** at the repo root.
- **`docs/adr/`**: read the ADRs that touch the area you're about to work in.

The `domain-modeling` skill (reached via `/grill-with-docs` and `/improve-codebase-architecture`) adds terms and ADRs when one is actually settled.

## File structure

Single context, with one set of terms shared by the client, the Mac host and the Windows host:

```
/
├── GLOSSARY.md
├── docs/adr/
│   └── 0001-<slug>.md
├── docs/guide/        ← how each area works (the project guide's topic files)
├── Vantage/
├── VantageHost/
└── WindowsHost/
```

## Use the glossary's vocabulary

When your output names a domain concept (an issue title, a refactor proposal, a hypothesis, a test name), use the term as `GLOSSARY.md` defines it. Don't drift to synonyms the glossary lists under _Avoid_.

If the concept you need isn't in the glossary yet, either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `domain-modeling`).

## Casement specifics

- `GLOSSARY.md` names things by the word the apps show (Casement, Casement Host, Mac, PC) and notes the code's Vantage name only where it differs, in line with the naming rule at the top of `CLAUDE.md`.
- The glossary says what a thing is; how it works, its rules and its debug flags live in the topic guides under `docs/guide/`. Link from one to the other rather than copying.
- A decision that is hard to reverse, surprising without context and the result of a real trade-off gets an ADR here, not only an agent memory note, so every agent and worktree sees it. A guide rule that rests on an ADR links to it.

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0001 (Tailscale only), but worth reopening because…_
