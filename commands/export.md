---
description: Export Claude Code session history as CSV or JSON
argument-hint: "<csv|json> [--today|--week|--month|--tag <name>]"
allowed-tools:
  - Bash
---

# claudetop-export

Export session history for analysis in spreadsheets or external tools.

If no format specified, default to `csv`.

```bash
claudetop-stats export $ARGUMENTS
```

Show the first 10 lines of output. Tell the user they can redirect to a file: `claudetop-stats export csv > ~/costs.csv`
