# Tether

> Swift Package scaffolded with [Monolith](https://github.com/Luminoid/Monolith).

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Luminoid/Tether.git", from: "0.1.0"),
]
```

## Development

```bash
brew bundle             # install swiftlint + swiftformat
make setup-hooks        # wire pre-commit lint + format
```

Build & test:

```bash
make build
make test
```

## Libraries

| Target | Dependencies |
|--------|--------------|
| TetherKit | — |

## Executables

| Binary | Dependencies | Run |
|--------|--------------|-----|
| `tether` | TetherKit | `swift run tether` |

## License

MIT. © Luminoid. See [LICENSE](LICENSE) and [CHANGELOG](CHANGELOG.md).
