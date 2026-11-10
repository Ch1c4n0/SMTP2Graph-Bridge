#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SMTP2Graph - HashiCorp Vault setup (Linux)
#
# EN: Sets up HashiCorp Vault and stores the Service Principal credentials
#     (Tenant ID, Client ID, Client Secret) in it. Linux version of
#     2-configurar-vault.ps1. Uses the Vault CLI inside the container, so you
#     only need Docker and curl on the host.
# PT: Configura o HashiCorp Vault e guarda nele as credenciais do Service
#     Principal (Tenant ID, Client ID, Client Secret). Versão Linux do
#     2-configurar-vault.ps1. Usa o Vault CLI de dentro do container: no
#     servidor só precisa de Docker e curl.
#
# HOW TO USE / COMO USAR:
#   cd /opt/smtp2graph
#   docker compose up -d --build
#   sudo ./scripts/2-configurar-vault.sh
# ---------------------------------------------------------------------------
set -uo pipefail

# Precisa de root: fala com o Docker e ajusta o dono dos arquivos do AppRole.
if [ "$(id -u)" -ne 0 ]; then
  echo "  Re-running with sudo / Executando de novo com sudo..."
  exec sudo -E bash "$0" "$@"
fi

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="${VAULT_CONTAINER:-smtp2graph-vault}"
PASTA_APPROLE="$RAIZ/vault/approle"
PASTA_UNSEAL="$RAIZ/vault/unseal"
API_SEGREDO="secret/data/smtp2graph/entra"
POLITICA="smtp2graph-read"
ROLE="smtp2graph"
UID_PONTE=10001          # usuário que roda a ponte dentro do container
GUID_RE='^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
TOKEN=""

C_CIANO='\033[36m'; C_VERDE='\033[32m'; C_AMARELO='\033[33m'; C_VERMELHO='\033[31m'; C_CINZA='\033[90m'; C_FIM='\033[0m'

titulo() { printf "\n${C_CIANO}=== %s / %s ===${C_FIM}\n" "$1" "$2"; }
msg()    { printf "  ${3:-}%s${C_FIM}\n  ${C_CINZA}%s${C_FIM}\n" "$1" "$2"; }
ok()     { msg "$1" "$2" "$C_VERDE"; }
aviso()  { msg "$1" "$2" "$C_AMARELO"; }
erro()   { msg "$1" "$2" "$C_VERMELHO"; }

# Executa o Vault CLI dentro do container (vi = com entrada pelo stdin)
v()  { docker exec    -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN="$TOKEN" "$CONTAINER" vault "$@" </dev/null; }
vi() { docker exec -i -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN="$TOKEN" "$CONTAINER" vault "$@"; }

sim_nao() {  # sim_nao "pergunta" padrao(s/n)
  local r sufixo="[y/N] (s/N)"; [ "$2" = "s" ] && sufixo="[Y/n] (S/n)"
  read -rp "  $1 $sufixo " r
  r="$(echo "$r" | tr '[:upper:]' '[:lower:]')"
  [ -z "$r" ] && r="$2"
  [[ "$r" =~ ^(y|yes|s|sim)$ ]]
}

ler_secreto() {  # ler_secreto "prompt" -> variável RESP
  RESP=""
  read -rsp "  $1: " RESP; echo
  RESP="$(printf '%s' "$RESP" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
}

salvar_arquivo() {  # salvar_arquivo caminho conteudo
  mkdir -p "$(dirname "$1")"
  ( umask 077; printf '%s' "$2" > "$1" )
}

estado() {  # imprime: nao_inicializado | selado | ok | erro
  local saida rc
  saida="$(v status -format=json 2>/dev/null)"; rc=$?
  if [ $rc -eq 1 ] || [ -z "$saida" ]; then echo erro; return; fi
  if grep -Eq '"initialized": *false' <<< "$saida"; then echo nao_inicializado; return; fi
  if grep -Eq '"sealed": *true' <<< "$saida"; then echo selado; return; fi
  echo ok
}

aguardar_ativo() {
  local i
  for i in $(seq 1 30); do
    if [ -n "$TOKEN" ]; then v token lookup >/dev/null 2>&1 && return 0
    else [ "$(estado)" = "ok" ] && return 0; fi
    sleep 2
  done
  erro "Vault did not become active." "O Vault não ficou ativo a tempo."; exit 1
}

desbloquear() {  # desbloquear [chave]
  if [ "$(estado)" != "selado" ]; then ok "Vault is already unsealed." "O Vault já está desbloqueado."; return; fi
  local chave="${1:-}"
  if [ -z "$chave" ]; then ler_secreto "Unseal key / Chave de desbloqueio"; chave="$RESP"; fi
  if ! v operator unseal "$chave" >/dev/null 2>&1; then erro "Unseal failed (wrong key?)." "Desbloqueio falhou (chave errada?)."; exit 1; fi
  aguardar_ativo
  ok "Vault unsealed." "Vault desbloqueado."
}

pedir_root_token() {
  while true; do
    ler_secreto "Root token"; TOKEN="$RESP"
    v token lookup >/dev/null 2>&1 && return 0
    erro "Invalid token, try again." "Token inválido, tente de novo."
  done
}

configurar_base() {
  titulo "Configuring Vault" "Configurando o Vault"
  local lista
  lista="$(v secrets list 2>/dev/null)"
  if ! grep -q '^secret/' <<< "$lista"; then
    v secrets enable -path=secret -version=2 -description="SMTP2Graph secrets" kv >/dev/null || exit 1
  fi
  ok "[OK] KV v2 secrets engine at secret/" "[OK] Cofre de segredos KV v2 em secret/"

  printf 'path "%s" {\n  capabilities = ["read"]\n}\n' "$API_SEGREDO" | vi policy write "$POLITICA" - >/dev/null || exit 1
  ok "[OK] Policy '$POLITICA' (read-only on secret/smtp2graph/entra)" \
     "[OK] Política '$POLITICA' (somente leitura em secret/smtp2graph/entra)"

  lista="$(v auth list 2>/dev/null)"
  if ! grep -q '^approle/' <<< "$lista"; then
    v auth enable approle >/dev/null || exit 1
  fi
  v write "auth/approle/role/$ROLE" token_policies="$POLITICA" token_ttl=1h token_max_ttl=4h \
    secret_id_ttl=0 secret_id_num_uses=0 >/dev/null || exit 1
  ok "[OK] AppRole '$ROLE' for the bridge" "[OK] AppRole '$ROLE' para a ponte"
}

novo_approle() {
  local antigo="" role_id secret_id
  [ -f "$PASTA_APPROLE/secret_id" ] && antigo="$(tr -d '\r\n' < "$PASTA_APPROLE/secret_id")"
  role_id="$(v read -field=role_id "auth/approle/role/$ROLE/role-id" | tr -d '\r\n')"
  secret_id="$(v write -f -field=secret_id "auth/approle/role/$ROLE/secret-id" | tr -d '\r\n')"
  if [ -z "$role_id" ] || [ -z "$secret_id" ]; then erro "Could not create the AppRole credentials." "Não consegui criar as credenciais do AppRole."; exit 1; fi
  salvar_arquivo "$PASTA_APPROLE/role_id" "$role_id"
  salvar_arquivo "$PASTA_APPROLE/secret_id" "$secret_id"
  # A ponte roda como o usuário 10001 dentro do container: ela precisa conseguir ler os arquivos.
  chown "$UID_PONTE:$UID_PONTE" "$PASTA_APPROLE/role_id" "$PASTA_APPROLE/secret_id"
  chmod 600 "$PASTA_APPROLE/role_id" "$PASTA_APPROLE/secret_id"
  if [ -n "$antigo" ]; then
    v write "auth/approle/role/$ROLE/secret-id/destroy" secret_id="$antigo" >/dev/null 2>&1 || true
  fi
  ok "[OK] AppRole credentials saved in vault/approle/ (role_id, secret_id)" \
     "[OK] Credenciais do AppRole salvas em vault/approle/ (role_id, secret_id)"
}

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

ler_guid() {  # ler_guid "rótulo" -> RESP
  while true; do
    read -rp "  $1: " RESP
    RESP="$(printf '%s' "$RESP" | tr -d '[:space:]')"
    [[ "$RESP" =~ $GUID_RE ]] && return 0
    erro "Invalid format. Expected: 00000000-0000-0000-0000-000000000000" \
         "Formato inválido. Esperado: 00000000-0000-0000-0000-000000000000"
  done
}

testar_entra() {  # testar_entra tenant client secret -> "" se OK, senão a mensagem de erro
  local resp
  resp="$(printf '%s' "$3" | curl -s -X POST "https://login.microsoftonline.com/$1/oauth2/v2.0/token" \
      --data-urlencode "client_id=$2" \
      --data-urlencode "client_secret@-" \
      --data-urlencode "scope=https://graph.microsoft.com/.default" \
      --data-urlencode "grant_type=client_credentials")" || { echo "network error / erro de rede (curl)"; return; }
  if grep -q '"access_token"' <<< "$resp"; then echo ""; return; fi
  local detalhe
  detalhe="$(sed -n 's/.*"error_description":"\([^"]*\)".*/\1/p' <<< "$resp" | sed 's/\\r\\n.*//' | head -n1 | cut -c1-200)"
  [ -z "$detalhe" ] && detalhe="$(printf '%s' "$resp" | tr -d '\r\n' | cut -c1-200)"
  [ -z "$detalhe" ] && detalhe="empty response / resposta vazia"
  echo "$detalhe"
}

gravar_service_principal() {
  titulo "Service Principal (Microsoft Entra ID)" "Service Principal (Microsoft Entra ID)"
  msg "Find these values in Entra ID > App registrations > your app > Overview." \
      "Veja estes valores em Entra ID > Registros de aplicativo > seu app > Visão geral."
  echo
  local tenant client secret falha
  ler_guid "Tenant ID (Directory ID / ID do diretório)"; tenant="$RESP"
  ler_guid "Client ID (Application ID / ID do aplicativo)"; client="$RESP"
  while true; do
    ler_secreto "Client Secret VALUE / VALOR do segredo (hidden / oculto)"; secret="$RESP"
    [ -z "$secret" ] && continue
    if [[ "$secret" =~ $GUID_RE ]]; then
      aviso "This looks like the Secret ID, not the secret VALUE. Copy the 'Value' column." \
            "Isso parece o ID do segredo, não o VALOR. Copie a coluna 'Valor'."
      sim_nao "Use it anyway? / Usar mesmo assim?" n || continue
    fi
    break
  done

  echo
  aviso "Testing sign-in to Microsoft Entra ID..." "Testando o login no Microsoft Entra ID..."
  falha="$(testar_entra "$tenant" "$client" "$secret")"
  if [ -n "$falha" ]; then
    erro "Sign-in FAILED: $falha" "O login FALHOU (confira Tenant ID, Client ID e o VALOR do segredo)."
    if ! sim_nao "Save to Vault anyway? / Gravar no Vault mesmo assim?" n; then
      aviso "Nothing was saved." "Nada foi gravado."; return
    fi
  else
    ok "[OK] Sign-in succeeded." "[OK] Login realizado com sucesso."
  fi

  printf '{"data":{"tenant_id":"%s","client_id":"%s","client_secret":"%s"}}' \
    "$(json_escape "$tenant")" "$(json_escape "$client")" "$(json_escape "$secret")" \
    | vi write "$API_SEGREDO" - >/dev/null || { erro "Could not write to Vault." "Não consegui gravar no Vault."; exit 1; }
  secret=""

  ok "[OK] Credentials stored in Vault at secret/smtp2graph/entra" \
     "[OK] Credenciais guardadas no Vault em secret/smtp2graph/entra"
  msg "The bridge picks them up within 5 minutes, or now with: docker compose restart smtp2graph" \
      "A ponte pega em até 5 minutos, ou agora com: docker compose restart smtp2graph"
}

primeira_configuracao() {
  titulo "First-time initialization" "Inicialização (primeira vez)"
  local saida chave root
  saida="$(v operator init -key-shares=1 -key-threshold=1 2>&1)" || { erro "$saida" "Falha ao inicializar o Vault."; exit 1; }
  chave="$(echo "$saida" | awk -F': ' '/Unseal Key 1/ {print $2}' | tr -d '\r ')"
  root="$(echo "$saida" | awk -F': ' '/Initial Root Token/ {print $2}' | tr -d '\r ')"
  if [ -z "$chave" ] || [ -z "$root" ]; then erro "Unexpected init output." "Saída inesperada da inicialização."; exit 1; fi

  printf "\n${C_AMARELO}  ****************************************************************\n"
  printf "   SAVE THESE TWO VALUES NOW (password manager). SHOWN ONLY ONCE!\n"
  printf "   GUARDE ESTES DOIS VALORES AGORA (cofre de senhas). SÓ APARECEM UMA VEZ!\n"
  printf "  ****************************************************************${C_FIM}\n\n"
  printf "   Unseal key / Chave de desbloqueio : %s\n" "$chave"
  printf "   Root token                        : %s\n\n" "$root"
  erro "Without the unseal key, the data in Vault can NEVER be recovered." \
       "Sem a chave de desbloqueio, os dados do Vault NUNCA mais podem ser recuperados."
  local resp=""
  while [ "$(echo "$resp" | tr '[:lower:]' '[:upper:]')" != "OK" ]; do
    read -rp "  Type OK after saving / Digite OK depois de guardar: " resp
  done
  clear

  desbloquear "$chave"
  TOKEN="$root"
  aguardar_ativo
  configurar_base
  novo_approle

  titulo "Automatic unseal" "Desbloqueio automático"
  msg "Vault locks itself (sealed) every time it restarts. Auto-unseal saves the key in" \
      "O Vault se tranca (sealed) toda vez que reinicia. O auto-unseal salva a chave em"
  msg "vault/unseal/unseal.key so it unlocks by itself. Recommended for an unattended server." \
      "vault/unseal/unseal.key para ele destrancar sozinho. Recomendado para servidor sem operador."
  if sim_nao "Enable auto-unseal? / Ativar o auto-unseal?" s; then
    salvar_arquivo "$PASTA_UNSEAL/unseal.key" "$chave"
    chmod 600 "$PASTA_UNSEAL/unseal.key"
    ok "[OK] Auto-unseal enabled." "[OK] Auto-unseal ativado."
  else
    aviso "After every restart, run this script and choose option 2 (unseal)." \
          "Depois de cada reinício, rode este script e escolha a opção 2 (desbloquear)."
  fi
  chave=""

  gravar_service_principal
  TOKEN=""; root=""

  titulo "Done" "Concluído"
  ok "Check the bridge: docker compose logs -f smtp2graph" "Confira a ponte: docker compose logs -f smtp2graph"
  ok "Expected: 'Login na Microsoft (OAuth) OK'" "Esperado: 'Login na Microsoft (OAuth) OK'"
}

mostrar_status() {
  titulo "Status" "Status"
  local e; e="$(estado)"
  echo "  Vault container              : $CONTAINER"
  echo "  State / Estado               : $e"
  echo "  AppRole files / Arquivos     : $( [ -s "$PASTA_APPROLE/role_id" ] && [ -s "$PASTA_APPROLE/secret_id" ] && echo True || echo False )"
  echo "  Auto-unseal                  : $( [ -s "$PASTA_UNSEAL/unseal.key" ] && echo True || echo False )"
}

# ------------------------------------------------------------------ main
titulo "SMTP2Graph - HashiCorp Vault setup" "SMTP2Graph - configuração do HashiCorp Vault"

command -v docker >/dev/null || { erro "Docker not found." "Docker não encontrado."; exit 1; }
command -v curl   >/dev/null || { erro "curl not found (apt install curl)." "curl não encontrado (apt install curl)."; exit 1; }
if ! grep -qx "$CONTAINER" <<< "$(docker ps --format '{{.Names}}')"; then
  erro "Container '$CONTAINER' is not running. Start it first: cd $RAIZ && docker compose up -d" \
       "O container '$CONTAINER' não está rodando. Ligue antes: cd $RAIZ && docker compose up -d"
  exit 1
fi

case "$(estado)" in
  erro) erro "Cannot talk to Vault inside the container." "Não consegui falar com o Vault dentro do container."; exit 1 ;;
  nao_inicializado) primeira_configuracao; exit 0 ;;
esac

while true; do
  echo
  echo "  1) Store/update Service Principal credentials  | Gravar/atualizar credenciais do Service Principal"
  echo "  2) Unseal Vault                                 | Desbloquear o Vault (unseal)"
  echo "  3) Generate new AppRole for the bridge          | Gerar novo AppRole para a ponte"
  echo "  4) Status                                       | Status"
  echo "  0) Exit                                         | Sair"
  read -rp "  Option / Opção: " op
  case "$op" in
    1) [ "$(estado)" = "selado" ] && desbloquear; pedir_root_token; configurar_base; gravar_service_principal; TOKEN="" ;;
    2) desbloquear ;;
    3) [ "$(estado)" = "selado" ] && desbloquear; pedir_root_token; configurar_base; novo_approle; TOKEN=""
       aviso "Restart the bridge: docker compose restart smtp2graph" "Reinicie a ponte: docker compose restart smtp2graph" ;;
    4) mostrar_status ;;
    0) exit 0 ;;
    *) erro "Invalid option." "Opção inválida." ;;
  esac
done
