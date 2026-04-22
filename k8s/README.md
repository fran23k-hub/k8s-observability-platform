Structure:
- apps/ → service source code
- charts/ → Helm deployments
- platform/ → shared infrastructure (Vault, monitoring, logging)
- automation/ → scripts & internal tooling
- configs/ → shared configs (alerts, database, etc.)
- manifests/ → legacy YAML (non-Helm)
