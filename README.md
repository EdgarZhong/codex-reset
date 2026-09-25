# CodexReset

<img width="1280" height="258" alt="image" src="https://github.com/user-attachments/assets/766c58f1-5264-469b-b641-bfe8787caefa" />

**An app that keeps Codex on the job.**

A tiny macOS menu-bar companion for the **Codex** desktop app. It watches your
5-hour / 1-week usage windows, detects conversations that were paused because
you hit your usage limit, and **automatically resumes them with “继续” (or any
command) the moment your usage is back** — so you never have to babysit the
"upgrade / try again at HH:MM" wall again.

> Not an official OpenAI product. CodexReset is an independent, open-source
> utility that only talks to the local Codex app on your own machine.

---


<img width="2048" height="1218" alt="image" src="https://github.com/user-attachments/assets/c4ddef65-c347-40ff-8487-13db60605e76" />




## Why

When a Codex session hits its usage cap, Codex pauses the active conversation
and says something like:

> You've reached your usage limit. Upgrade your plan or top up to continue, or
> try again at 13:18.

Usage resets on a rolling **5-hour window**, and every paused conversation has
to be manually continued by switching to it and typing "继续". If you run
several agents/projects at once, that's a lot of babysitting.

**CodexReset does it for you.**

## Features

- **Menu-bar status** — live 5h / 1w usage bars, next-reset countdown, plan
  type and credit balance at a glance.
- **Auto-resume** — when the 5h window resets, CodexReset automatically sends
  "继续" to the conversations you've checked. Nothing is pre-selected: tick the
  paused conversations you care about (or hit "select all"), or add any other
  conversation from the full list.
- **Browse all conversations** — every project and its conversations are listed
  (grouped by project, archived and sub-agent threads filtered out). Check any
  conversation, even one that isn't paused yet, to have it resumed too. The
  section can be collapsed in the main panel.
- **Double-click to jump** — opens the conversation in Codex via its deep link.
- **Usage history timeline** — each 5h window reset is recorded automatically,
  so you can see the exact time usage recovers every day.
- **Detects pauses for you** — conversations stopped by
  `usageLimitExceeded` are found automatically, with their recovery time shown.
- **CLI mode** — `--query` prints usage, `--continue <thread_id>` resumes one
  thread from the terminal.

### How auto-resume works

Two channels, in order:

1. **Codex Desktop GUI** — deep-links into the selected conversation, focuses
   the input box, pastes your command and sends it with **⌘Enter** (requires
   **Accessibility** permission). Success is confirmed from the local thread
   history database before the conversation is marked handled.
2. **Bundled app-server fallback** — starts a private stdio app-server only when
   the GUI path clearly did not submit the command. An uncertain GUI result is
   checked again before any further send.

## Requirements

- macOS 14+
- The [Codex desktop app](https://openai.com/codex/) (this is a companion, it
  doesn't bundle Codex itself)
- Xcode command line tools for building (`xcode-select --install`)

## Install & run

### Build

```bash
git clone https://github.com/EdgarZhong/codex-reset.git
cd codex-reset
swift build -c release
```

### Use as a menu-bar app (recommended)

```bash
./make_app.sh              # builds & installs /Applications/CodexReset.app
./install_launchagent.sh   # (optional) auto-start at login via LaunchAgent
```

Then click the menu-bar icon to open the panel. For GUI continuation:

- Give **CodexReset** Accessibility permission (System Settings →
  Privacy & Security → Accessibility) so the GUI channel can type into
  Codex. The panel shows a live "Accessibility" status so you know when it's
  granted.

### CLI only

```bash
.build/release/CodexReset --query                    # usage + paused threads
.build/release/CodexReset --continue <thread_id>     # resume one thread now
```

## Configuration

| Setting | Where |
|---|---|
| Auto-resume on/off | panel toggle `用量恢复后自动继续` |
| Command sent | panel `指令` field (default `继续`) |
| Which conversations | checkbox list in the panel |
| `CODEX_HOME` | env var overrides `~/.codex` (advanced) |

The interface and its built-in default continuation command follow the macOS
preferred language (Chinese or English). Custom commands are preserved. There
is currently no separate settings window.

## Logs

Activity logs are written to `~/Library/Logs/CodexReset/codex-reset.log`. The
app keeps the current file and four numbered archives (`.1` through `.4`),
each limited to 1 MiB, for a maximum of 5 MiB of log content. Rotation happens
before a new entry would cross the limit. The panel continues to show the most
recent 100 entries from the current run. The log directory and files are
readable only by the current user.

To run the file rotation checks with the Swift command-line tools:

```bash
swiftc -parse-as-library Sources/CodexReset/RotatingFileLogger.swift Tests/CodexResetTests/RotatingFileLoggerTests.swift -o /tmp/codex-reset-logger-tests
/tmp/codex-reset-logger-tests
```

## Privacy

- CodexReset reads **local** Codex files and talks to its own bundled
  app-server over stdio when the GUI cannot submit a command.
- Activity logs stay in `~/Library/Logs/CodexReset/` and may contain local
  conversation titles and paths.
- No data leaves your machine. No account, no telemetry.

## Project documents

| Content | Path |
|---|---|
| Collaboration rules and safety boundaries | [`AGENTS.md`](AGENTS.md) |
| Current progress and handoff | [`CLAUDE.md`](CLAUDE.md) |
| First implementation round | [`docs/autonomous-runs/20260925-gui-tier1.md`](docs/autonomous-runs/20260925-gui-tier1.md) |

## Building the .app icon

`Resources/generate_icon.py` turns a transparent-background/irregular
`logo.png` into a proper `AppIcon.icns` (center-padded to a square canvas,
LANCZOS scaling). Replace `logo.png` and re-run `./make_app.sh`.

## Contributing / disclaimer

PRs and issues are welcome. This project was reverse-engineered from local
behavior and may break when Codex updates — please open an issue with the
error and version. Use at your own risk; automated "继续" will consume usage in
the normal way within your plan.

## License

[MIT](LICENSE) © 2026 BOYSO
