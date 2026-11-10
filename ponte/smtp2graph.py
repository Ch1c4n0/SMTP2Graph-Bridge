"""
SMTP2Graph - Ponte SMTP -> Microsoft Graph
==========================================

O que este programa faz:
  1. Fica "escutando" como se fosse um servidor de e-mail (SMTP) comum.
  2. Sua aplicação (ERP, emissor de notas, etc.) manda o e-mail para cá, por SMTP.
  3. A ponte confere se quem mandou tem permissão (rede, usuário/senha, remetente).
  4. A ponte entrega o e-mail para a Microsoft usando a API do Microsoft Graph,
     com autenticação moderna (OAuth). Nada de senha de usuário do Microsoft 365.

As credenciais do Service Principal (Tenant ID, Client ID e segredo) ficam
guardadas no HashiCorp Vault. O restante da configuração vem do arquivo .env.
"""

import asyncio
import base64
import hmac
import ipaddress
import logging
import os
import signal
import ssl
import sys
import threading
import time
import uuid
import warnings
from collections import deque
from email.parser import BytesHeaderParser
from email import message_from_bytes
from email.policy import compat32
from email.utils import getaddresses

import msal
import requests
from aiosmtpd.controller import Controller
from aiosmtpd.smtp import AuthResult, LoginPassword

# ---------------------------------------------------------------------------
# 1) Leitura da configuração
# ---------------------------------------------------------------------------


def env(nome, padrao=None):
    valor = os.environ.get(nome, padrao)
    return valor.strip() if isinstance(valor, str) else valor


def env_bool(nome, padrao=False):
    valor = env(nome)
    if valor is None or valor == "":
        return padrao
    return valor.lower() in ("1", "true", "sim", "yes", "on")


def env_lista(nome, padrao=""):
    return [item.strip() for item in (env(nome, padrao) or "").split(",") if item.strip()]


# --- HashiCorp Vault (onde ficam as credenciais do Service Principal) ---
VAULT_ADDR = (env("VAULT_ADDR", "") or "").rstrip("/")
VAULT_SECRET_PATH = env("VAULT_SECRET_PATH", "secret/data/smtp2graph/entra").strip("/")
VAULT_ROLE_ID_FILE = env("VAULT_ROLE_ID_FILE", "/vault-approle/role_id")
VAULT_SECRET_ID_FILE = env("VAULT_SECRET_ID_FILE", "/vault-approle/secret_id")
# De quanto em quanto tempo (segundos) a ponte relê o Vault (para pegar um segredo novo sem reiniciar)
VAULT_REFRESH_SECONDS = int(env("VAULT_REFRESH_SECONDS", "300"))
VAULT_TIMEOUT = 10

# Alternativa SEM Vault (não recomendada): credenciais direto no .env
TENANT_ID = env("TENANT_ID")
CLIENT_ID = env("CLIENT_ID")
CLIENT_SECRET = env("CLIENT_SECRET")

# Caixas que podem ser usadas como remetente (MAIL FROM). Ex.: notas@suaempresa.com.br
ALLOWED_SENDERS = [s.lower() for s in env_lista("ALLOWED_SENDERS")]

# Redes (IPs) que podem usar a ponte. Padrão: só redes privadas/internas.
ALLOWED_NETWORKS = env_lista(
    "ALLOWED_NETWORKS", "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,127.0.0.0/8"
)

# Usuário/senha SMTP que a SUA APLICAÇÃO vai usar para falar com a ponte (opcional).
# Não tem nada a ver com o Microsoft 365: é uma senha só entre a aplicação e a ponte.
SMTP_USERNAME = env("SMTP_USERNAME", "")
SMTP_PASSWORD = env("SMTP_PASSWORD", "")

# TLS (criptografia) opcional entre a aplicação e a ponte.
TLS_CERT_FILE = env("TLS_CERT_FILE", "/certs/cert.pem")
TLS_KEY_FILE = env("TLS_KEY_FILE", "/certs/key.pem")
REQUIRE_TLS = env_bool("REQUIRE_TLS", False)

LISTEN_HOST = env("LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(env("LISTEN_PORT", "2525"))
SERVER_NAME = env("SERVER_NAME", "smtp2graph")

# O Graph aceita no máximo ~4 MB por envio. O e-mail é convertido para base64
# (fica ~33% maior), então 2,9 MB de e-mail original é o limite seguro.
MAX_MESSAGE_BYTES = int(env("MAX_MESSAGE_BYTES", "2900000"))
MAX_RECIPIENTS = int(env("MAX_RECIPIENTS", "100"))

# Limite do Exchange Online: 30 mensagens por minuto por caixa.
MAX_MSGS_PER_MINUTE = int(env("MAX_MSGS_PER_MINUTE", "30"))

GRAPH_TIMEOUT = int(env("GRAPH_TIMEOUT", "60"))
GRAPH_MAX_RETRIES = int(env("GRAPH_MAX_RETRIES", "4"))
LOG_LEVEL = env("LOG_LEVEL", "INFO").upper()

GRAPH_URL = "https://graph.microsoft.com/v1.0"

logging.basicConfig(
    level=LOG_LEVEL,
    format="%(asctime)s %(levelname)-7s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    stream=sys.stdout,
)
log = logging.getLogger("smtp2graph")
# O aiosmtpd avisa sobre AUTH sem TLS a cada conexão; a ponte já avisa isso uma vez no início.
warnings.filterwarnings("ignore", module="aiosmtpd")
# Evita que bibliotecas encham o log
logging.getLogger("mail.log").setLevel(logging.ERROR)
logging.getLogger("msal").setLevel(logging.WARNING)
logging.getLogger("urllib3").setLevel(logging.WARNING)


def validar_configuracao():
    """Para o programa com uma mensagem clara se faltar algo importante."""
    erros = []
    if not VAULT_ADDR:
        for nome, valor in (("TENANT_ID", TENANT_ID), ("CLIENT_ID", CLIENT_ID), ("CLIENT_SECRET", CLIENT_SECRET)):
            if not valor or "0000-0000" in valor or "cole-" in valor:
                erros.append(f"{nome} não foi preenchido no .env (ou configure VAULT_ADDR para usar o Vault)")
    if not ALLOWED_SENDERS:
        erros.append("ALLOWED_SENDERS está vazio (informe a caixa que envia, ex.: notas@suaempresa.com.br)")
    if bool(SMTP_USERNAME) != bool(SMTP_PASSWORD):
        erros.append("Preencha SMTP_USERNAME e SMTP_PASSWORD juntos (ou deixe os dois vazios)")
    if SMTP_PASSWORD and len(SMTP_PASSWORD) < 12:
        erros.append("SMTP_PASSWORD precisa ter pelo menos 12 caracteres")
    try:
        redes = [ipaddress.ip_network(r, strict=False) for r in ALLOWED_NETWORKS]
    except ValueError as e:
        erros.append(f"ALLOWED_NETWORKS inválido: {e}")
        redes = []
    if erros:
        for e in erros:
            log.error("CONFIGURAÇÃO: %s", e)
        sys.exit(1)
    return redes


REDES_PERMITIDAS = validar_configuracao()

# ---------------------------------------------------------------------------
# 2) Credenciais do Service Principal, lidas do HashiCorp Vault
#
#    A ponte entra no Vault com o "AppRole" (role_id + secret_id, dois arquivos
#    criados pelo script scripts\2-configurar-vault.ps1) e lê o segredo
#    secret/smtp2graph/entra, que tem tenant_id, client_id e client_secret.
#    Ela só tem permissão de LEITURA nesse único caminho.
# ---------------------------------------------------------------------------


class ErroVault(Exception):
    """O Vault ainda não está pronto (desligado, selado, sem AppRole ou sem o segredo)."""


_vault_token = None
_vault_token_expira = 0.0


def _ler_arquivo(caminho):
    try:
        with open(caminho, encoding="utf-8-sig") as f:
            return f.read().strip()
    except OSError:
        return ""


def _checar_resposta_vault(resp, etapa):
    if resp.status_code < 300:
        return
    if resp.status_code == 503:
        raise ErroVault("o Vault está SELADO (sealed). Rode o desbloqueio (unseal) ou ative o auto-unseal")
    if resp.status_code == 404:
        raise ErroVault(f"segredo '{VAULT_SECRET_PATH}' não encontrado. Grave os dados do Service Principal "
                        "com scripts\\2-configurar-vault.ps1")
    if resp.status_code in (400, 403):
        raise ErroVault(f"o Vault recusou o {etapa} (HTTP {resp.status_code}). Gere um novo AppRole com "
                        "scripts\\2-configurar-vault.ps1")
    raise ErroVault(f"erro HTTP {resp.status_code} no {etapa}: {resp.text[:200]}")


def _vault_login():
    global _vault_token, _vault_token_expira
    role_id, secret_id = _ler_arquivo(VAULT_ROLE_ID_FILE), _ler_arquivo(VAULT_SECRET_ID_FILE)
    if not role_id or not secret_id:
        raise ErroVault("arquivos do AppRole (vault\\approle\\role_id e secret_id) não encontrados. "
                        "Rode scripts\\2-configurar-vault.ps1")
    resp = requests.post(f"{VAULT_ADDR}/v1/auth/approle/login",
                         json={"role_id": role_id, "secret_id": secret_id}, timeout=VAULT_TIMEOUT)
    _checar_resposta_vault(resp, "login do AppRole")
    auth = resp.json()["auth"]
    _vault_token = auth["client_token"]
    _vault_token_expira = time.monotonic() + max(int(auth.get("lease_duration") or 3600) - 60, 30)


def _ler_credenciais_vault():
    try:
        for tentativa in (1, 2):
            if not _vault_token or time.monotonic() >= _vault_token_expira:
                _vault_login()
            resp = requests.get(f"{VAULT_ADDR}/v1/{VAULT_SECRET_PATH}",
                                headers={"X-Vault-Token": _vault_token}, timeout=VAULT_TIMEOUT)
            if resp.status_code == 403 and tentativa == 1:
                _forcar_novo_login_vault()  # token do Vault venceu ou foi revogado: entra de novo
                continue
            _checar_resposta_vault(resp, "leitura do segredo")
            dados = resp.json()["data"]["data"]
            break
    except requests.RequestException as e:
        raise ErroVault(f"não consegui conectar no Vault em {VAULT_ADDR} ({e.__class__.__name__})") from e

    faltando = [c for c in ("tenant_id", "client_id", "client_secret") if not dados.get(c)]
    if faltando:
        raise ErroVault(f"o segredo no Vault está incompleto (faltando: {', '.join(faltando)})")
    return dados["tenant_id"].strip(), dados["client_id"].strip(), dados["client_secret"].strip()


def _forcar_novo_login_vault():
    global _vault_token
    _vault_token = None


def ler_credenciais():
    if VAULT_ADDR:
        return _ler_credenciais_vault()
    return TENANT_ID, CLIENT_ID, CLIENT_SECRET


# ---------------------------------------------------------------------------
# 2b) Login na Microsoft (token OAuth) - o msal guarda o token em cache
#     e só pede um novo quando o atual está para vencer (~1 hora).
# ---------------------------------------------------------------------------

_credenciais = None          # (tenant_id, client_id, client_secret)
_credenciais_lidas_em = 0.0
_msal_app = None
_token_lock = threading.Lock()


def _atualizar_credenciais(forcar=False):
    """Relê o Vault de tempos em tempos. Se o Vault falhar, continua com o que já está em memória."""
    global _credenciais, _credenciais_lidas_em, _msal_app
    if not forcar and _credenciais and time.monotonic() - _credenciais_lidas_em < VAULT_REFRESH_SECONDS:
        return
    try:
        novas = ler_credenciais()
    except ErroVault as e:
        if _credenciais is None:
            raise
        log.warning("Não consegui reler o Vault (%s). Continuo usando as credenciais em memória.", e)
        _credenciais_lidas_em = time.monotonic()
        return
    if novas != _credenciais:
        if _credenciais is not None:
            log.info("As credenciais do Service Principal mudaram no Vault: recarregando.")
        _credenciais, _msal_app = novas, None
    _credenciais_lidas_em = time.monotonic()


def _pedir_token():
    global _msal_app
    if _msal_app is None:
        tenant_id, client_id, client_secret = _credenciais
        _msal_app = msal.ConfidentialClientApplication(
            client_id=client_id, client_credential=client_secret,
            authority=f"https://login.microsoftonline.com/{tenant_id}",
        )
    return _msal_app.acquire_token_for_client(scopes=["https://graph.microsoft.com/.default"])


def obter_token():
    with _token_lock:
        _atualizar_credenciais()
        resultado = _pedir_token()
        if "access_token" not in resultado and VAULT_ADDR and resultado.get("error") in (
                "invalid_client", "unauthorized_client"):
            # O segredo pode ter sido trocado no Vault agora há pouco: relê e tenta mais uma vez.
            _atualizar_credenciais(forcar=True)
            resultado = _pedir_token()
    if "access_token" not in resultado:
        raise RuntimeError(f"{resultado.get('error')}: {resultado.get('error_description', '')}".strip())
    return resultado["access_token"]


def client_id_atual():
    return _credenciais[1] if _credenciais else "?"


# ---------------------------------------------------------------------------
# 3) Controle de velocidade: no máximo N mensagens por minuto por caixa
# ---------------------------------------------------------------------------

_envios_por_caixa: dict[str, deque] = {}
_travas_por_caixa: dict[str, asyncio.Lock] = {}


async def aguardar_vez(caixa):
    trava = _travas_por_caixa.setdefault(caixa, asyncio.Lock())
    async with trava:
        historico = _envios_por_caixa.setdefault(caixa, deque())
        while True:
            agora = time.monotonic()
            while historico and agora - historico[0] >= 60:
                historico.popleft()
            if len(historico) < MAX_MSGS_PER_MINUTE:
                historico.append(agora)
                return
            espera = 60 - (agora - historico[0]) + 0.1
            log.info("Limite de %s msg/min atingido para %s; aguardando %.0fs", MAX_MSGS_PER_MINUTE, caixa, espera)
            await asyncio.sleep(espera)


# ---------------------------------------------------------------------------
# 4) Preparação da mensagem
# ---------------------------------------------------------------------------


def _so_texto(valor, limite=200):
    """Deixa a mensagem de erro em uma linha só, sem caracteres estranhos (regra do SMTP)."""
    texto = " ".join(str(valor).split())
    return texto.encode("ascii", "replace").decode("ascii")[:limite]


def garantir_destinatarios(conteudo: bytes, destinatarios_envelope: list[str]) -> bytes:
    """
    O Graph entrega para quem está nos cabeçalhos To/Cc/Bcc do e-mail.
    Alguns sistemas mandam cópias ocultas só no "envelope" SMTP (RCPT TO), sem cabeçalho.
    Aqui garantimos que todo destinatário do envelope apareça (como Bcc, invisível).
    """
    cabecalhos = BytesHeaderParser(policy=compat32).parsebytes(conteudo)
    nos_cabecalhos = {
        endereco.lower()
        for campo in ("To", "Cc", "Bcc")
        for _, endereco in getaddresses(cabecalhos.get_all(campo, []))
        if endereco
    }
    faltando = [d for d in destinatarios_envelope if d.lower() not in nos_cabecalhos]
    if not faltando:
        return conteudo

    if cabecalhos.get_all("Bcc"):
        # Caso raro: já existe Bcc; reescreve o cabeçalho juntando tudo.
        msg = message_from_bytes(conteudo, policy=compat32)
        existentes = [e for _, e in getaddresses(msg.get_all("Bcc", [])) if e]
        del msg["Bcc"]
        msg["Bcc"] = ", ".join(existentes + faltando)
        return msg.as_bytes()

    # Caso comum: só adiciona uma linha "Bcc:" no topo do e-mail.
    return f"Bcc: {', '.join(faltando)}\r\n".encode("ascii", "ignore") + conteudo


# ---------------------------------------------------------------------------
# 5) Envio pelo Microsoft Graph (com novas tentativas automáticas)
# ---------------------------------------------------------------------------


class ErroTemporario(Exception):
    """Falha passageira: a aplicação deve tentar de novo mais tarde (SMTP 451)."""


class ErroPermanente(Exception):
    """Falha definitiva: não adianta tentar de novo sem corrigir algo (SMTP 550/554)."""


def enviar_via_graph(caixa: str, conteudo_mime: bytes, id_msg: str) -> str:
    corpo = base64.b64encode(conteudo_mime)
    url = f"{GRAPH_URL}/users/{caixa}/sendMail"

    for tentativa in range(1, GRAPH_MAX_RETRIES + 1):
        try:
            token = obter_token()
        except Exception as e:  # erro ao fazer login na Microsoft
            raise ErroTemporario(f"Falha no login OAuth: {e}") from e

        try:
            resp = requests.post(
                url,
                data=corpo,
                headers={
                    "Authorization": f"Bearer {token}",
                    "Content-Type": "text/plain",  # = "estou mandando o e-mail no formato MIME, em base64"
                },
                timeout=GRAPH_TIMEOUT,
            )
        except requests.RequestException as e:
            motivo = f"Erro de rede ao falar com o Graph: {e}"
            resp = None
        else:
            request_id = resp.headers.get("request-id", "-")
            if resp.status_code == 202:
                return request_id

            try:
                erro = resp.json().get("error", {})
                motivo = f"{erro.get('code', resp.status_code)}: {erro.get('message', '')}"
            except ValueError:
                motivo = f"HTTP {resp.status_code}: {resp.text[:200]}"
            motivo = f"{motivo} (request-id {request_id})"

            if resp.status_code in (400, 401, 403, 404, 413):
                raise ErroPermanente(motivo)

        # Chegou aqui = erro passageiro (429 "devagar", 5xx, rede). Espera e tenta de novo.
        if tentativa < GRAPH_MAX_RETRIES:
            espera = 2 ** tentativa
            if resp is not None and resp.headers.get("Retry-After", "").isdigit():
                espera = min(int(resp.headers["Retry-After"]), 120)
            log.warning("[%s] Tentativa %d/%d falhou (%s). Nova tentativa em %ss",
                        id_msg, tentativa, GRAPH_MAX_RETRIES, motivo, espera)
            time.sleep(espera)

    raise ErroTemporario(motivo)


# ---------------------------------------------------------------------------
# 6) O "servidor SMTP": regras de cada etapa da conversa SMTP
# ---------------------------------------------------------------------------


def ip_permitido(ip: str) -> bool:
    try:
        endereco = ipaddress.ip_address(ip)
    except ValueError:
        return False
    if endereco.version == 6 and endereco.ipv4_mapped:
        endereco = endereco.ipv4_mapped
    return any(endereco in rede for rede in REDES_PERMITIDAS)


def autenticador(server, session, envelope, mechanism, auth_data):
    """Confere o usuário/senha que a aplicação informou (se a autenticação estiver ligada)."""
    ip = session.peer[0] if session.peer else "?"
    if not ip_permitido(ip) or not isinstance(auth_data, LoginPassword):
        return AuthResult(success=False, handled=False)
    usuario_ok = hmac.compare_digest(auth_data.login, SMTP_USERNAME.encode())
    senha_ok = hmac.compare_digest(auth_data.password, SMTP_PASSWORD.encode())
    if usuario_ok and senha_ok:
        return AuthResult(success=True)
    log.warning("Login SMTP recusado de %s (usuário: %s)", ip, auth_data.login.decode(errors="replace"))
    return AuthResult(success=False, handled=False)


class Ponte:
    async def handle_MAIL(self, server, session, envelope, address, mail_options):
        ip = session.peer[0] if session.peer else "?"
        if not ip_permitido(ip):
            log.warning("Conexão recusada: IP %s fora de ALLOWED_NETWORKS", ip)
            return "550 5.7.1 Seu IP nao tem permissao para usar este servidor"
        if address.lower() not in ALLOWED_SENDERS:
            log.warning("Remetente recusado: %s (IP %s). Permitidos: %s", address, ip, ", ".join(ALLOWED_SENDERS))
            return f"550 5.7.1 Remetente {_so_texto(address, 80)} nao autorizado nesta ponte"
        envelope.mail_from = address
        envelope.mail_options.extend(mail_options)
        return "250 2.1.0 OK"

    async def handle_RCPT(self, server, session, envelope, address, rcpt_options):
        if len(envelope.rcpt_tos) >= MAX_RECIPIENTS:
            return f"452 4.5.3 Maximo de {MAX_RECIPIENTS} destinatarios por mensagem"
        envelope.rcpt_tos.append(address)
        return "250 2.1.5 OK"

    async def handle_DATA(self, server, session, envelope):
        id_msg = uuid.uuid4().hex[:8]
        ip = session.peer[0] if session.peer else "?"
        caixa = envelope.mail_from
        conteudo = envelope.original_content or envelope.content
        if isinstance(conteudo, str):
            conteudo = conteudo.encode("utf-8")

        log.info("[%s] Recebido de %s | remetente=%s | destinatarios=%d | tamanho=%.1f KB",
                 id_msg, ip, caixa, len(envelope.rcpt_tos), len(conteudo) / 1024)

        try:
            conteudo = garantir_destinatarios(conteudo, envelope.rcpt_tos)
        except Exception as e:
            log.error("[%s] E-mail mal formado: %s", id_msg, e)
            return "554 5.6.0 Mensagem mal formada"

        await aguardar_vez(caixa.lower())

        try:
            request_id = await asyncio.to_thread(enviar_via_graph, caixa, conteudo, id_msg)
        except ErroPermanente as e:
            log.error("[%s] RECUSADO pelo Graph: %s", id_msg, e)
            return f"550 5.7.1 Graph recusou: {_so_texto(e)}"
        except ErroTemporario as e:
            log.error("[%s] FALHA TEMPORÁRIA: %s", id_msg, e)
            return f"451 4.4.0 Falha temporaria, tente novamente: {_so_texto(e)}"
        except Exception as e:  # qualquer outro problema inesperado
            log.exception("[%s] Erro inesperado", id_msg)
            return f"451 4.3.0 Erro interno: {_so_texto(e)}"

        log.info("[%s] ENVIADO via Graph | para=%s | request-id=%s", id_msg, ", ".join(envelope.rcpt_tos), request_id)
        return f"250 2.0.0 OK: entregue ao Microsoft 365 (id {id_msg})"


# ---------------------------------------------------------------------------
# 7) Inicialização
# ---------------------------------------------------------------------------


def contexto_tls():
    if os.path.isfile(TLS_CERT_FILE) and os.path.isfile(TLS_KEY_FILE):
        ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(TLS_CERT_FILE, TLS_KEY_FILE)
        return ctx
    return None


def main():
    log.info("Iniciando SMTP2Graph...")

    origem = f"HashiCorp Vault ({VAULT_ADDR})" if VAULT_ADDR else "arquivo .env"
    log.info("Credenciais do Service Principal: %s", origem)

    # Só começa a aceitar e-mails depois que conseguir ler o Vault e entrar na Microsoft.
    while True:
        try:
            obter_token()
            log.info("Login na Microsoft (OAuth) OK para o app %s", client_id_atual())
            break
        except ErroVault as e:
            log.warning("Aguardando o Vault: %s. Nova tentativa em 15s.", e)
            time.sleep(15)
        except Exception as e:
            log.error("Login na Microsoft falhou: %s", e)
            log.error("Confira Tenant ID, Client ID e o VALOR do segredo (scripts\\2-configurar-vault.ps1). "
                      "Nova tentativa em 60s.")
            time.sleep(60)

    tls = contexto_tls()
    if REQUIRE_TLS and not tls:
        log.error("REQUIRE_TLS=true, mas não encontrei %s e %s", TLS_CERT_FILE, TLS_KEY_FILE)
        sys.exit(1)

    autenticacao_ligada = bool(SMTP_USERNAME)
    parametros = dict(
        hostname=LISTEN_HOST,
        port=LISTEN_PORT,
        server_hostname=SERVER_NAME,
        ident="SMTP2Graph",
        data_size_limit=MAX_MESSAGE_BYTES,
        tls_context=tls,
        require_starttls=REQUIRE_TLS,
        auth_require_tls=bool(tls) and REQUIRE_TLS,
        ready_timeout=10,
    )
    if autenticacao_ligada:
        parametros.update(authenticator=autenticador, auth_required=True)
    else:
        # Sem usuário/senha configurado: nem anuncia AUTH, para não confundir a aplicação
        parametros.update(auth_exclude_mechanism=["LOGIN", "PLAIN"], auth_require_tls=True)

    controller = Controller(Ponte(), **parametros)
    controller.start()

    log.info("Ouvindo SMTP em %s:%s", LISTEN_HOST, LISTEN_PORT)
    log.info("Remetentes permitidos: %s", ", ".join(ALLOWED_SENDERS))
    log.info("Redes permitidas: %s", ", ".join(ALLOWED_NETWORKS))
    log.info("Autenticação SMTP: %s | TLS (STARTTLS): %s%s",
             "LIGADA" if autenticacao_ligada else "desligada",
             "disponível" if tls else "desligado",
             " (obrigatório)" if REQUIRE_TLS else "")
    if not autenticacao_ligada:
        log.warning("Sem usuário/senha SMTP: qualquer máquina das redes permitidas pode enviar. "
                    "Em produção, preencha SMTP_USERNAME e SMTP_PASSWORD.")

    parar = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: parar.set())
    signal.signal(signal.SIGINT, lambda *_: parar.set())
    parar.wait()

    log.info("Encerrando...")
    controller.stop()


if __name__ == "__main__":
    main()
