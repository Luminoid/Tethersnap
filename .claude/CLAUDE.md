# Tether — Claude Code Guide

> Swift Package with targets: TetherKit, tether.
> **Inherits general Swift/UIKit standards from [workspace CLAUDE.md](../../.claude/CLAUDE.md).** This file contains Tether-specific rules only.

## Libraries

| Target | Dependencies | Default isolation |
|--------|--------------|-------------------|
| TetherKit | — | — |

## Executables

| Binary | Dependencies | Run |
|--------|--------------|-----|
| `tether` | TetherKit | `swift run tether` |

---

## Build & Test

```bash
swift build
swift test
```

Run executable sibling target:

```bash
swift run tether
```

```bash
make check  # SwiftLint + SwiftFormat
```

---

*Optimized for Claude Code • Last updated: 2026-08-29*
