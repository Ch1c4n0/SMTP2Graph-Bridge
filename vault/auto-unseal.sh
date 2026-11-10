#!/bin/sh
# ---------------------------------------------------------------
# Auto-unseal: desbloqueia o Vault sozinho depois de reiniciar.
# Auto-unseal: unseals Vault automatically after a restart.
#
# Só funciona se o arquivo vault/unseal/unseal.key existir
# (o script 2-configurar-vault.ps1 pergunta se você quer criá-lo).
# Only works if vault/unseal/unseal.key exists
# (2-configurar-vault.ps1 asks whether you want to create it).
# ---------------------------------------------------------------
KEY_FILE=/unseal/unseal.key
echo "auto-unseal: monitoring $VAULT_ADDR"

while true; do
  if [ -s "$KEY_FILE" ]; then
    STATUS=$(vault status -format=json 2>/dev/null)
    if echo "$STATUS" | grep -Eq '"initialized": *true' && echo "$STATUS" | grep -Eq '"sealed": *true'; then
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Vault is sealed - unsealing / Vault selado - desbloqueando..."
      if vault operator unseal "$(tr -d '\r\n ' < "$KEY_FILE")" >/dev/null 2>&1; then
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Vault unsealed / Vault desbloqueado"
      else
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ERROR: unseal failed - check vault/unseal/unseal.key"
      fi
    fi
  fi
  sleep 10
done
