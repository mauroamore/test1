#!/usr/bin/env bash

# Avvio Raspberry: il codice viene aggiornato solo dall'interfaccia amministrativa.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "Avvio Gestione Comande..."
exec node server.js
