#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SMTP2Graph - Firewall (Linux)
#
# EN: Allows port 25 (bridge SMTP) ONLY from your internal network.
#     IMPORTANT: ufw/firewalld rules do NOT protect ports published by Docker,
#     because Docker writes its own iptables rules first. The correct place is
#     the DOCKER-USER chain, which is what this script uses.
# PT: Libera a porta 25 (SMTP da ponte) SOMENTE para a sua rede interna.
#     IMPORTANTE: regras do ufw/firewalld NÃO protegem portas publicadas pelo
#     Docker, porque o Docker grava as regras de iptables dele antes. O lugar
#     certo é a cadeia DOCKER-USER, que é o que este script usa.
#
# HOW TO USE / COMO USAR:
#   sudo ./scripts/3-liberar-firewall-linux.sh 192.168.0.0/24          # aplica agora
#   sudo ./scripts/3-liberar-firewall-linux.sh 192.168.0.0/24,172.16.0.0/12   # + redes do Docker (app-teste)
#   sudo ./scripts/3-liberar-firewall-linux.sh 192.168.0.0/24 --persistir   # e mantém após reiniciar
#   sudo ./scripts/3-liberar-firewall-linux.sh --remover               # remove a regra
# ---------------------------------------------------------------------------
set -euo pipefail

PORTA="${PORTA:-25}"
UNIDADE="/etc/systemd/system/smtp2graph-firewall.service"
RAIZ_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

if [ "$(id -u)" -ne 0 ]; then exec sudo -E bash "$0" "$@"; fi
command -v iptables >/dev/null || { echo "iptables not found / iptables não encontrado"; exit 1; }

if ! iptables -nL DOCKER-USER >/dev/null 2>&1; then
  echo "  Chain DOCKER-USER not found: is Docker running? / Cadeia DOCKER-USER não existe: o Docker está rodando?"
  exit 1
fi

remover_regras() {
  # Remove todas as regras desta ponte (identificadas pelo comentário)
  while read -r num; do
    [ -n "$num" ] && iptables -D DOCKER-USER "$num"
  done < <(iptables -L DOCKER-USER --line-numbers -n | awk '/smtp2graph/ {print $1}' | sort -rn)
}

if [ "${1:-}" = "--remover" ]; then
  remover_regras
  if [ -f "$UNIDADE" ]; then systemctl disable --now smtp2graph-firewall.service >/dev/null 2>&1 || true; rm -f "$UNIDADE"; systemctl daemon-reload; fi
  echo "  Rule removed / Regra removida."
  exit 0
fi

REDE="${1:-}"
if [ -z "$REDE" ]; then
  echo "  Usage / Uso: sudo $0 <REDE/CIDR[,REDE2...]> [--persistir]   ex.: 192.168.0.0/24,172.16.0.0/12"
  exit 1
fi

# Para cada rede permitida: RETURN (deixa passar). Depois: DROP para o resto.
# (--ctorigdstport olha a porta original, antes do Docker redirecionar para 2525)
BASE="-p tcp -m conntrack --ctstate NEW --ctorigdstport $PORTA -m comment --comment smtp2graph"
REGRAS=()
IFS=',' read -ra REDES <<< "$REDE"
for r in "${REDES[@]}"; do REGRAS+=("$BASE -s $r -j RETURN"); done
REGRAS+=("$BASE -j DROP")

remover_regras
pos=1
for regra in "${REGRAS[@]}"; do
  # shellcheck disable=SC2086
  iptables -I DOCKER-USER $pos $regra
  pos=$((pos + 1))
done
echo "  [OK] Port $PORTA allowed only from $REDE / Porta $PORTA liberada somente para $REDE"

if [ "${2:-}" = "--persistir" ]; then
  cat > "$UNIDADE" <<EOF
[Unit]
Description=SMTP2Graph - restrict port $PORTA to $REDE (DOCKER-USER)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$RAIZ_SCRIPT $REDE

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable smtp2graph-firewall.service >/dev/null
  echo "  [OK] Rule will be re-applied after reboot (systemd: smtp2graph-firewall.service)"
  echo "       A regra será reaplicada após reiniciar (systemd: smtp2graph-firewall.service)"
else
  echo "  Note: this rule is lost on reboot. Use --persistir to keep it."
  echo "  Obs.: esta regra some ao reiniciar. Use --persistir para mantê-la."
fi

echo
iptables -L DOCKER-USER -n --line-numbers | sed 's/^/  /'
echo
echo "  Never port-forward port $PORTA on your router. / Nunca faça port forward da porta $PORTA no roteador."
echo "  Keep SMTP_USERNAME/SMTP_PASSWORD set in .env.  / Mantenha SMTP_USERNAME/SMTP_PASSWORD no .env."
