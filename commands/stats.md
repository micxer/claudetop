---
description: Show Claude Code spending analytics (today/week/month/all/tag/branch)
argument-hint: "[today|week|month|all|tag <name>|branch [name]]"
allowed-tools:
  - Bash
---

# claudetop-stats

Run claudetop spending analytics and display the results.

If no arguments provided, default to `week`.

```bash
claudetop-stats $ARGUMENTS
```

Run the command and display the full formatted output to the user. Do not summarize.
