#!/usr/bin/env bash
# Exporta os diagramas Mermaid (.mmd) para PNG. Requer Node.js.
# Uso: ./export.sh
set -euo pipefail
cd "$(dirname "$0")"
for f in *.mmd; do
  npx -y @mermaid-js/mermaid-cli -i "$f" -o "${f%.mmd}.png" -b white -s 2
done
