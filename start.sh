#!/usr/bin/env bash

# Avvio Raspberry: verifica GitHub prima di avviare Node.js.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "Controllo aggiornamenti GitHub..."
if git fetch --quiet origin main; then
  local_commit="$(git rev-parse HEAD)"
  remote_commit="$(git rev-parse origin/main)"

  if [[ "$local_commit" != "$remote_commit" ]]; then
    echo "Aggiornamento disponibile: applico origin/main..."
    if git pull --ff-only origin main; then
      echo "Aggiornamento completato."
    else
      echo "ATTENZIONE: aggiornamento non applicato; avvio la versione locale." >&2
    fi
  else
    echo "Codice già aggiornato."
  fi
else
  echo "ATTENZIONE: GitHub non raggiungibile; avvio la versione locale." >&2
fi

echo "Avvio Gestione Comande..."
exec node server.js
