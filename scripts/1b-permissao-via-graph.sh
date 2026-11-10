#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SMTP2Graph - Mail.Send via Microsoft Graph (Linux, Azure CLI)
#
# EN: Linux version of 1b-permissao-via-graph.ps1 (Option B of Step 4).
#     Uses the Azure CLI ("az") to call the Microsoft Graph API.
#     The "restringir" action (Application Access Policy) needs Exchange
#     PowerShell, so it runs the .ps1 with pwsh.
# PT: Versão Linux do 1b-permissao-via-graph.ps1 (Opção B do Passo 4).
#     Usa o Azure CLI ("az") para chamar a API do Microsoft Graph.
#     A ação "restringir" (Application Access Policy) precisa do PowerShell do
#     Exchange, então ela roda o .ps1 com o pwsh.
#
# HOW TO USE / COMO USAR:
#   ./scripts/1b-permissao-via-graph.sh verificar  <APP_ID>
#   ./scripts/1b-permissao-via-graph.sh conceder   <APP_ID>
#   ./scripts/1b-permissao-via-graph.sh remover    <APP_ID>
#   ./scripts/1b-permissao-via-graph.sh restringir <APP_ID> notas@suaempresa.com.br
# ---------------------------------------------------------------------------
set -euo pipefail

ACAO="${1:-}"; APP_ID="${2:-}"; CAIXA="${3:-}"
GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"   # "Microsoft Graph" (igual em todos os tenants)
GRAPH="https://graph.microsoft.com/v1.0"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

uso() { sed -n '15,18p' "$0" | sed 's/^#//'; exit 1; }
[ -z "$ACAO" ] || [ -z "$APP_ID" ] && uso

if [ "$ACAO" = "restringir" ]; then
  command -v pwsh >/dev/null || { echo "  pwsh (PowerShell 7) required / necessário. See / Veja 1-configurar-permissao-exchange.sh"; exit 1; }
  exec pwsh -NoLogo -NoProfile -File "$DIR/1b-permissao-via-graph.ps1" -AppId "$APP_ID" -Acao Restringir -Caixa "$CAIXA" -UseDeviceCode
fi

command -v az >/dev/null || {
  echo "  Azure CLI not found / não encontrado:  curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash"
  exit 1
}

# Login (por código, funciona sem navegador no servidor)
if ! az account show >/dev/null 2>&1; then
  echo "  Sign in / Faça login (admin):"
  az login --use-device-code --allow-no-subscriptions >/dev/null
fi

# IDs: Service Principal do Microsoft Graph, permissão Mail.Send (tipo Aplicativo) e o SP do seu app
GRAPH_SP="$(az ad sp show --id "$GRAPH_APP_ID" --query id -o tsv)"
MAIL_SEND="$(az ad sp show --id "$GRAPH_APP_ID" \
  --query "appRoles[?value=='Mail.Send' && contains(allowedMemberTypes, 'Application')].id | [0]" -o tsv)"
APP_SP="$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null || true)"
if [ -z "$APP_SP" ]; then
  echo "  Service Principal not found for AppId $APP_ID / não encontrado (confira em Aplicativos empresariais)"
  exit 1
fi

atribuicoes() {
  az rest --method GET --uri "$GRAPH/servicePrincipals/$APP_SP/appRoleAssignments" \
    --query "value[?appRoleId=='$MAIL_SEND' && resourceId=='$GRAPH_SP'].id" -o tsv
}

case "$ACAO" in
  verificar)
    echo
    echo "  AppId              : $APP_ID"
    echo "  Service Principal  : $APP_SP   (= Object ID / ID do objeto)"
    if [ -n "$(atribuicoes)" ]; then
      echo "  Mail.Send (Entra)  : GRANTED / CONCEDIDO"
      echo
      echo "  ! The app can send as ANY mailbox unless an Application Access Policy restricts it."
      echo "  ! O app pode enviar como QUALQUER caixa, a menos que uma Application Access Policy restrinja."
      echo "  If you use Option A (RBAC), remove it / Se usa a Opção A (RBAC), remova:  $0 remover $APP_ID"
    else
      echo "  Mail.Send (Entra)  : not granted / não concedido"
      echo
      echo "  OK for Option A (RBAC) / Correto para a Opção A (RBAC)."
    fi
    ;;
  conceder)
    if [ -n "$(atribuicoes)" ]; then echo "  Mail.Send already granted / já concedido."; exit 0; fi
    echo "  WARNING: Mail.Send granted in Entra ID applies to ALL mailboxes in the company."
    echo "  ATENÇÃO: Mail.Send concedido no Entra ID vale para TODAS as caixas da empresa."
    read -rp "  Continue? / Continuar? [y/N] (s/N) " r
    [[ "${r,,}" =~ ^(y|yes|s|sim)$ ]] || exit 0
    az rest --method POST --uri "$GRAPH/servicePrincipals/$APP_SP/appRoleAssignments" \
      --headers "Content-Type=application/json" \
      --body "{\"principalId\":\"$APP_SP\",\"resourceId\":\"$GRAPH_SP\",\"appRoleId\":\"$MAIL_SEND\"}" >/dev/null
    echo "  [OK] Mail.Send granted / concedido (admin consent)."
    echo
    echo "  Now restrict it to the invoice mailbox / Agora restrinja à caixa de notas:"
    echo "    $0 restringir $APP_ID notas@suaempresa.com.br"
    ;;
  remover)
    ids="$(atribuicoes)"
    [ -z "$ids" ] && { echo "  Nothing to remove / Nada para remover."; exit 0; }
    for id in $ids; do
      az rest --method DELETE --uri "$GRAPH/servicePrincipals/$APP_SP/appRoleAssignments/$id" >/dev/null
    done
    echo "  [OK] Mail.Send grant removed / Concessão Mail.Send removida."
    ;;
  *) uso ;;
esac
