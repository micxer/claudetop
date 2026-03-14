---
description: Open the claudetop web dashboard showing spending charts and session history
argument-hint: ""
allowed-tools:
  - Bash
---

# claudetop-dashboard

Generate and open the claudetop web dashboard in your browser. Shows spending over time, cost by project/model/branch, efficiency trends, and a sortable session table.

```bash
claudetop-dashboard 2>/dev/null || echo "claudetop-dashboard not found. Install: cd ~/claudetop && ./install.sh"
```

Tell the user the dashboard has been opened in their browser.
