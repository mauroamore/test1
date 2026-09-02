#!/usr/bin/env bash

# Avvio Raspberry: il codice viene aggiornato solo dall'interfaccia amministrativa.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

# Use the tested LTS runtime when nvm is installed on the Raspberry.
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [ -s "$NVM_DIR/nvm.sh" ]; then
  . "$NVM_DIR/nvm.sh"
  nvm use 22 >/dev/null
fi

echo "Avvio Gestione Comande..."
exec node server.js
