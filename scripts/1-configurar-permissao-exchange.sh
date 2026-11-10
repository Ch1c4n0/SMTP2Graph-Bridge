#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SMTP2Graph - Exchange permission (Linux) / Permissão no Exchange (Linux)
#
# EN: The Exchange Online cmdlets (RBAC for Applications) only exist in
#     PowerShell. On Linux this script runs 1-configurar-permissao-exchange.ps1
#     with PowerShell 7 (pwsh) and device-code sign-in (works without a browser
#     on the server: open the link on any computer and type the code).
#     Tip: this step does NOT need to run on the Docker server. You can also
#     run the .ps1 from any Windows PC.
# PT: Os comandos do Exchange Online (RBAC para Aplicativos) só existem no
#     PowerShell. No Linux este script roda o 1-configurar-permissao-exchange.ps1
#     com o PowerShell 7 (pwsh) e login por código (funciona sem navegador no
#     servidor: abra o link em qualquer computador e digite o código).
#     Dica: este passo NÃO precisa rodar no servidor do Docker. Você também
#     pode rodar o .ps1 em qualquer PC Windows.
#
# HOW TO USE / COMO USAR:
#   ./scripts/1-configurar-permissao-exchange.sh \
#       -AppId    "ID-DO-APLICATIVO" \
#       -ObjectId "ID-DO-OBJETO-DE-APLICATIVOS-EMPRESARIAIS" \
#       -Caixa    "notas@suaempresa.com.br"
# ---------------------------------------------------------------------------
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v pwsh >/dev/null; then
  cat <<'TXT'
  PowerShell 7 (pwsh) not found / não encontrado.

  Ubuntu / Debian:
    sudo apt-get update && sudo apt-get install -y wget
    source /etc/os-release
    wget -q "https://packages.microsoft.com/config/$ID/$VERSION_ID/packages-microsoft-prod.deb"
    sudo dpkg -i packages-microsoft-prod.deb && sudo apt-get update && sudo apt-get install -y powershell

  RHEL / Rocky / Alma:
    sudo dnf install -y https://packages.microsoft.com/config/rhel/9/packages-microsoft-prod.rpm
    sudo dnf install -y powershell

  Or run 1-configurar-permissao-exchange.ps1 from a Windows PC.
  Ou rode o 1-configurar-permissao-exchange.ps1 em um PC Windows.
TXT
  exit 1
fi

exec pwsh -NoLogo -NoProfile -File "$DIR/1-configurar-permissao-exchange.ps1" -UseDeviceCode "$@"
