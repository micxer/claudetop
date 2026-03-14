---
description: Update Claude model pricing to latest rates
argument-hint: ""
allowed-tools:
  - Bash
---

# claudetop-pricing

Fetch the latest Claude model pricing from the claudetop GitHub repo and update the local cache. Pricing updates automatically via daily cron, but use this to force an immediate update.

```bash
~/.claude/update-claudetop-pricing.sh 2>&1 || echo "Run: cd ~/claudetop && ./install.sh"
```

Display the output showing current pricing per model.
