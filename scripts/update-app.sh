#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
backup_dir=".update-backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup_dir"
cp -p ristorante-state.json "$backup_dir/ristorante-state.json" 2>/dev/null || true
cp -p restaurant-config.json "$backup_dir/restaurant-config.json" 2>/dev/null || true
cp -p menu-cache.json "$backup_dir/menu-cache.json" 2>/dev/null || true

git fetch --quiet origin main
git merge-base --is-ancestor HEAD origin/main || {
  echo "La copia locale non è un antenato di origin/main: aggiornamento annullato" >&2
  exit 21
}

state_backup="$backup_dir/ristorante-state.json"
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
  if git ls-files --error-unmatch -- ristorante-state.json >/dev/null 2>&1; then
    git checkout -- ristorante-state.json
  fi
  git pull --ff-only origin main
  if [[ -f "$state_backup" ]]; then
    cp -p "$state_backup" ristorante-state.json
  fi
fi

npm install --omit=dev
npm run check

echo "Codice aggiornato e verificato. Il servizio verrà riavviato dal backend."
