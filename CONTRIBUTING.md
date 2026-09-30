# Contributing

Thanks for your interest in Porthole. Bug reports, ideas, and pull requests are all welcome.

## Reporting bugs and ideas

[Open an issue](https://github.com/dlev02/Porthole/issues/new/choose) using the bug report or feature request form. For connection problems, include whether Tailscale shows both devices as connected. For security problems, see [SECURITY.md](SECURITY.md) instead.

## Pull requests

1. Read [`CLAUDE.md`](CLAUDE.md). It's the engineering guide for the whole project: architecture, conventions, debug flags, and the decisions behind them. The research notes in [`docs/research`](docs/research/README.md) back the trickier parts.
2. Keep each pull request to one change, and describe what it does for someone using the app.
3. Run `scripts/check.sh` before you open it. It runs both Swift test suites and builds the host and the iOS and macOS clients. If you touched `WindowsHost/`, also run `dotnet test --solution Vantage.Windows.slnx` from that folder.
4. If you change a wire message, update both the Swift and the C# golden vectors (see "Golden vectors" in `CLAUDE.md`).

## Licensing of contributions

Porthole is licensed under the [GPL-3.0](LICENSE). By submitting a contribution, you agree that:

- It's your own work, or you have the right to submit it.
- It's licensed under the GPL-3.0, like the rest of the project.
- Drew Levinson may also distribute it as part of Porthole through app stores, such as Apple's App Store, whose terms add restrictions that the GPL alone wouldn't allow.

The last point keeps the free App Store version possible. It doesn't change your rights, or anyone else's, under the GPL.
