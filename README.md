# claudetop

**htop for your Claude Code sessions.**

Real-time status line showing project context, token usage, cost insights, cache efficiency, smart alerts, and a plugin system for extensibility.

```
14:32  my-project/src/app  Opus  20m 0s  +256/-43
152.3K in / 45.2K out  ████░░░░░░ 38%  $3.47  $5.10/hr
cache: 66%  efficiency: $0.012/line  opus:$4.38  sonnet:$0.88  haiku:$0.23
main*  |  ♫ Artist - Song
```

## Features

### Line 1 — Context
- **Time of day** — turns magenta after 10pm (go to bed)
- **Project name** + relative path within project
- **Model** (Opus / Sonnet / Haiku)
- **Session duration**
- **Lines changed** (+added / -removed)

### Line 2 — Resources
- **Token counts** (formatted as K/M)
- **Context window bar** — green <50%, yellow 50-80%, red 80%+
- **Compact warning** — `COMPACT SOON` at 80%+, `~X% left` at 70%+
- **Actual session cost** (green)
- **Cost velocity** — $/hr burn rate (green <$3, yellow <$8, red $8+)

### Line 3 — Efficiency
- **Cache hit ratio** — green ≥60%, yellow ≥30%, red <30%
- **Output efficiency** — cost per line of code changed
- **Model cost comparison** — cache-aware estimates for Opus, Sonnet, Haiku (current model **bolded**)

### Line 4 — Alerts + Plugins
Smart alerts that only appear when triggered:

| Alert | Trigger | Action |
|-------|---------|--------|
| `$5 MARK` / `$10 MARK` / `$25 MARK` | Cost crosses threshold | Check if you're getting value |
| `CONSIDER FRESH SESSION` | >2hrs + >60% context | Start fresh to reset context |
| `LOW CACHE` | <20% cache after 5min | Something forced a full re-read |
| `BURN RATE` | >$15/hr velocity | Check for runaway subagents |
| `SPINNING?` | >$1 spent, 0 lines changed | Research loop without output |
| `TRY /fast` | >$0.05/line on Opus | Switch model for this task |

Plus output from any enabled plugins (see below).

## Install

```bash
git clone https://github.com/liorwn/claudetop.git
cd claudetop
chmod +x install.sh
./install.sh
```

Then restart Claude Code.

### Manual install

```bash
cp claudetop.sh ~/.claude/claudetop.sh
chmod +x ~/.claude/claudetop.sh
mkdir -p ~/.claude/claudetop.d
```

Add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/claudetop.sh",
    "padding": 1
  }
}
```

## Requirements

- Claude Code (with status line support)
- `jq` — JSON parsing (`brew install jq` / `apt install jq`)
- `bc` — math (pre-installed on macOS and most Linux)

## Plugins

Drop any executable script into `~/.claude/claudetop.d/` and it becomes part of your status line.

Each plugin:
- Receives the full session JSON on **stdin**
- Outputs a single formatted string (ANSI colors OK)
- Has a **1 second timeout** (slow plugins are skipped)
- Failures are silently ignored

### Bundled plugins

| Plugin | Default | What it does |
|--------|---------|-------------|
| `git-branch.sh` | Enabled | Current branch + dirty indicator (`main*`) |

### Example plugins

Copy from `~/.claude/claudetop.d/_examples/` to enable:

```bash
# Enable Spotify now-playing
cp ~/.claude/claudetop.d/_examples/spotify.sh ~/.claude/claudetop.d/

# Enable weather
cp ~/.claude/claudetop.d/_examples/weather.sh ~/.claude/claudetop.d/

# Enable Hacker News ticker
cp ~/.claude/claudetop.d/_examples/news-ticker.sh ~/.claude/claudetop.d/
```

| Plugin | What it does |
|--------|-------------|
| `spotify.sh` | Now playing on Spotify (macOS) |
| `weather.sh` | Current weather via wttr.in (cached 30min). Set `CLAUDETOP_WEATHER_LOCATION` |
| `news-ticker.sh` | Top Hacker News story (cached 15min) |
| `pomodoro.sh` | Focus timer. `touch ~/.claude/pomodoro-start` to begin |
| `system-load.sh` | CPU load average (macOS + Linux) |

### Write your own

```bash
#!/bin/bash
# ~/.claude/claudetop.d/my-plugin.sh
# Receives session JSON on stdin

JSON=$(cat)
MODEL=$(echo "$JSON" | jq -r '.model.display_name')

# Output a single formatted string
printf "\033[90mmodel: %s\033[0m" "$MODEL"
```

Make it executable: `chmod +x ~/.claude/claudetop.d/my-plugin.sh`

## How model cost comparison works

claudetop shows what your session would cost on each Claude model. The estimates are **cache-aware** — they use your actual cache hit ratio (from the current turn) to extrapolate across cumulative token usage, then apply each model's pricing:

| Model | Input | Cache Write | Cache Read | Output |
|-------|-------|-------------|------------|--------|
| Opus | $15/MTok | $18.75/MTok | $1.50/MTok | $75/MTok |
| Sonnet | $3/MTok | $3.75/MTok | $0.30/MTok | $15/MTok |
| Haiku | $0.80/MTok | $1.00/MTok | $0.08/MTok | $4/MTok |

The current model's cost is **bolded** so you can instantly compare.

## Color coding

All metrics use traffic-light colors:
- **Green** — healthy, efficient
- **Yellow** — worth noticing
- **Red** — take action

| Metric | Green | Yellow | Red |
|--------|-------|--------|-----|
| Cost velocity | <$3/hr | <$8/hr | ≥$8/hr |
| Cache ratio | ≥60% | ≥30% | <30% |
| Efficiency | <$0.01/line | <$0.05/line | ≥$0.05/line |
| Context bar | <50% | 50-80% | ≥80% |

## License

MIT
