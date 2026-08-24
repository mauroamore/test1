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
  git checkout -- ristorante-state.json
  git pull --ff-only origin main
  cp -p "$state_backup" ristorante-state.json 2>/dev/null || true
fi

npm install --omit=dev
npm run check

echo "Codice aggiornato e verificato. Riavviare il servizio gestione-comande.service per applicare la nuova versione."
