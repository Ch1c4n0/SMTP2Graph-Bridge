"""
Aplicação de TESTE - simula um sistema emissor de Nota Fiscal
=============================================================

Ela tem uma tela de "Configuração de SMTP" igual à de muitos ERPs.
Você preenche servidor, porta, usuário e senha, clica em Enviar, e ela
manda um e-mail com uma nota fiscal de exemplo (PDF + XML) em anexo.

Serve para provar que a ponte SMTP2Graph está funcionando ANTES de
configurar a aplicação de produção.

Abra no navegador: http://localhost:8080
"""

import io
import json
import os
import smtplib
import ssl
import sys
from contextlib import redirect_stderr
from datetime import datetime
from email.message import EmailMessage
from email.utils import formataddr, make_msgid

from flask import Flask, render_template, request

app = Flask(__name__)

# Valores que já aparecem preenchidos na tela (vêm do docker-compose.yml)
PADROES = {
    "servidor": os.environ.get("SMTP_SERVIDOR", "host.docker.internal"),
    "porta": os.environ.get("SMTP_PORTA", "25"),
    "usuario": os.environ.get("SMTP_USUARIO", ""),
    "senha": "",
    "seguranca": os.environ.get("SMTP_SEGURANCA", "nenhuma"),
    "ignorar_certificado": True,
    "remetente": os.environ.get("SMTP_REMETENTE", "notas@suaempresa.com.br"),
    "nome_remetente": os.environ.get("NOME_EMPRESA", "Sua Empresa Ltda"),
    "destinatario": "",
    "numero": "000123",
}


# Configurações salvas pelo botão "Salvar configurações" (volume Docker, sobrevive a reinícios)
ARQUIVO_CONFIG = os.environ.get("ARQUIVO_CONFIG", "/app/dados/config.json")
CAMPOS = ("servidor", "porta", "usuario", "senha", "seguranca", "remetente",
          "nome_remetente", "destinatario", "numero")


def carregar_config() -> dict:
    """Padrões do docker-compose.yml + o que foi salvo na tela."""
    dados = dict(PADROES)
    dados["salvar_senha"] = False
    try:
        with open(ARQUIVO_CONFIG, encoding="utf-8") as f:
            salvo = json.load(f)
        for campo in CAMPOS + ("ignorar_certificado", "salvar_senha"):
            if campo in salvo:
                dados[campo] = salvo[campo]
    except FileNotFoundError:
        pass
    except (OSError, ValueError) as e:
        print(f"AVISO não consegui ler {ARQUIVO_CONFIG}: {e}", file=sys.stdout, flush=True)
    return dados


def salvar_config(dados) -> None:
    salvo = {c: dados[c] for c in CAMPOS if c != "senha"}
    salvo["ignorar_certificado"] = dados["ignorar_certificado"]
    salvo["salvar_senha"] = dados["salvar_senha"]
    if dados["salvar_senha"]:
        salvo["senha"] = dados["senha"]
    os.makedirs(os.path.dirname(ARQUIVO_CONFIG), exist_ok=True)
    temporario = ARQUIVO_CONFIG + ".tmp"
    with open(temporario, "w", encoding="utf-8") as f:
        json.dump(salvo, f, ensure_ascii=False, indent=2)
    os.replace(temporario, ARQUIVO_CONFIG)


def gerar_pdf_exemplo(numero: str) -> bytes:
    """Cria um PDF simples (1 página) escrito à mão, sem bibliotecas extras."""
    linhas = [
        "DANFE - DOCUMENTO DE TESTE (SEM VALOR FISCAL)",
        f"Nota Fiscal numero {numero}",
        f"Emitida em {datetime.now():%d/%m/%Y %H:%M}",
        "Enviada pela ponte SMTP2Graph",
    ]
    texto = "BT /F1 14 Tf 60 780 Td 20 TL " + " ".join(f"({l}) Tj T*" for l in linhas) + " ET"
    objetos = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R "
        b"/Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length %d >>\nstream\n%s\nendstream" % (len(texto), texto.encode("latin-1")),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    pdf = io.BytesIO()
    pdf.write(b"%PDF-1.4\n")
    posicoes = []
    for i, obj in enumerate(objetos, start=1):
        posicoes.append(pdf.tell())
        pdf.write(b"%d 0 obj\n%s\nendobj\n" % (i, obj))
    inicio_xref = pdf.tell()
    pdf.write(b"xref\n0 %d\n0000000000 65535 f \n" % (len(objetos) + 1))
    for p in posicoes:
        pdf.write(b"%010d 00000 n \n" % p)
    pdf.write(b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objetos) + 1, inicio_xref))
    return pdf.getvalue()


def gerar_xml_exemplo(numero: str) -> bytes:
    """Cria um XML parecido com o de uma NF-e (apenas para teste, sem valor fiscal)."""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<nfeProc versao="4.00" xmlns="http://www.portalfiscal.inf.br/nfe">
  <!-- ARQUIVO DE TESTE - SEM VALOR FISCAL -->
  <NFe>
    <infNFe Id="NFeTESTE{numero}" versao="4.00">
      <ide><nNF>{numero}</nNF><dhEmi>{datetime.now().isoformat(timespec="seconds")}</dhEmi></ide>
      <emit><xNome>EMPRESA DE TESTE</xNome></emit>
      <total><ICMSTot><vNF>100.00</vNF></ICMSTot></total>
    </infNFe>
  </NFe>
</nfeProc>
""".encode("utf-8")


def montar_email(dados) -> EmailMessage:
    numero = dados["numero"] or "000123"
    msg = EmailMessage()
    msg["Subject"] = f"[TESTE] Nota Fiscal nº {numero} - {dados['nome_remetente']}"
    msg["From"] = formataddr((dados["nome_remetente"], dados["remetente"]))
    msg["To"] = dados["destinatario"]
    msg["Message-ID"] = make_msgid(domain=dados["remetente"].split("@")[-1])
    msg.set_content(
        f"Olá,\n\nSegue em anexo a Nota Fiscal nº {numero} (TESTE, sem valor fiscal).\n\n"
        f"Este e-mail foi enviado pela aplicação de teste através da ponte SMTP2Graph.\n\n"
        f"Atenciosamente,\n{dados['nome_remetente']}"
    )
    msg.add_alternative(
        f"""<p>Olá,</p>
<p>Segue em anexo a Nota Fiscal nº <b>{numero}</b> (<i>TESTE, sem valor fiscal</i>).</p>
<p>Este e-mail foi enviado pela aplicação de teste através da ponte <b>SMTP2Graph</b>.</p>
<p>Atenciosamente,<br>{dados['nome_remetente']}</p>""",
        subtype="html",
    )
    msg.add_attachment(gerar_pdf_exemplo(numero), maintype="application", subtype="pdf",
                       filename=f"DANFE_{numero}.pdf")
    msg.add_attachment(gerar_xml_exemplo(numero), maintype="application", subtype="xml",
                       filename=f"NFe_{numero}.xml")
    return msg


def esconder_senha(log_smtp: str) -> str:
    """Não mostra na tela as linhas que carregam usuário/senha (mesmo codificados)."""
    linhas, autenticando = [], False
    for linha in log_smtp.splitlines():
        if linha.startswith("send:") and ("AUTH" in linha.upper() or autenticando):
            autenticando = True
            linhas.append("send: '********** (credenciais escondidas)'")
            continue
        if linha.startswith("reply:") and (b"235" in linha.encode() or b"535" in linha.encode()):
            autenticando = False
        if len(linha) > 300:  # o conteúdo do e-mail (anexos) é enorme; mostra só o começo
            linha = linha[:300] + f" ... [+{len(linha) - 300} caracteres]"
        linhas.append(linha)
    return "\n".join(linhas)


def enviar(dados, so_testar=False):
    """Faz o envio SMTP exatamente como um ERP faria. Devolve (sucesso, mensagem, log).

    so_testar=True: conecta, faz a segurança, o login e pergunta se o remetente é aceito
    (MAIL FROM), mas desiste antes de mandar o e-mail (RSET). Nada é enviado.
    """
    contexto = ssl.create_default_context()
    if dados["ignorar_certificado"]:
        contexto.check_hostname = False
        contexto.verify_mode = ssl.CERT_NONE

    saida = io.StringIO()
    try:
        porta = int(dados["porta"])
        with redirect_stderr(saida):
            if dados["seguranca"] == "ssl":
                smtp = smtplib.SMTP_SSL(dados["servidor"], porta, timeout=180, context=contexto)
            else:
                smtp = smtplib.SMTP(dados["servidor"], porta, timeout=180)
            smtp.set_debuglevel(1)  # grava a "conversa" SMTP para mostrar na tela
            with smtp:
                smtp.ehlo()
                if dados["seguranca"] == "starttls":
                    smtp.starttls(context=contexto)
                    smtp.ehlo()
                if dados["usuario"]:
                    smtp.login(dados["usuario"], dados["senha"])
                if so_testar:
                    codigo, resposta = smtp.mail(dados["remetente"])
                    if codigo != 250:
                        raise smtplib.SMTPSenderRefused(codigo, resposta, dados["remetente"])
                    smtp.rset()
                    recusados = None
                else:
                    recusados = smtp.send_message(montar_email(dados))
        if so_testar:
            return True, ("Comunicação OK: a ponte respondeu, a segurança e o login funcionaram e o "
                          f"remetente {dados['remetente']} é aceito. Nenhum e-mail foi enviado. "
                          "(Este teste não confere a permissão no Microsoft 365: isso só aparece "
                          "ao enviar.)"), esconder_senha(saida.getvalue())
        if recusados:
            return False, f"Alguns destinatários foram recusados: {recusados}", esconder_senha(saida.getvalue())
        return True, "E-mail aceito pela ponte e entregue ao Microsoft 365!", esconder_senha(saida.getvalue())
    except smtplib.SMTPAuthenticationError as e:
        msg = f"Usuário ou senha SMTP recusados ({e.smtp_code}): {e.smtp_error.decode(errors='replace')}"
    except smtplib.SMTPNotSupportedError as e:
        msg = f"O servidor não aceita este recurso: {e}. Dica: se a ponte não tem usuário/senha, deixe Usuário vazio."
    except smtplib.SMTPResponseException as e:
        msg = f"O servidor respondeu com erro {e.smtp_code}: {e.smtp_error.decode(errors='replace')}"
    except smtplib.SMTPRecipientsRefused as e:
        msg = "Destinatário recusado: " + "; ".join(
            f"{k} -> {v[0]} {v[1].decode(errors='replace')}" for k, v in e.recipients.items())
    except smtplib.SMTPSenderRefused as e:
        msg = f"Remetente recusado ({e.smtp_code}): {e.smtp_error.decode(errors='replace')}"
    except (ConnectionRefusedError, TimeoutError, OSError) as e:
        msg = (f"Não consegui conectar em {dados['servidor']}:{dados['porta']} ({e}). "
               "A ponte está rodando? O servidor e a porta estão certos? O firewall está liberado?")
    except ValueError:
        msg = "A porta precisa ser um número (ex.: 25)."
    return False, msg, esconder_senha(saida.getvalue())


@app.route("/", methods=["GET", "POST"])
def index():
    dados = carregar_config()
    senha_salva = dados["senha"] if dados.get("salvar_senha") else ""
    resultado = None
    if request.method == "POST":
        for campo in CAMPOS:
            dados[campo] = request.form.get(campo, "").strip()
        dados["ignorar_certificado"] = request.form.get("ignorar_certificado") == "on"
        dados["salvar_senha"] = request.form.get("salvar_senha") == "on"
        if not dados["senha"] and dados["salvar_senha"]:
            dados["senha"] = senha_salva  # campo vazio = continua usando a senha salva
        acao = request.form.get("acao", "enviar")

        if acao == "salvar":
            try:
                salvar_config(dados)
                extra = " (com a senha)" if dados["salvar_senha"] else " (sem a senha)"
                resultado = {"ok": True, "mensagem": "Configurações salvas" + extra +
                             ". Elas voltam preenchidas quando você abrir a página de novo.", "log": ""}
            except OSError as e:
                resultado = {"ok": False, "mensagem": f"Não consegui salvar em {ARQUIVO_CONFIG}: {e}", "log": ""}
        elif acao == "testar":
            ok, mensagem, log_smtp = enviar(dados, so_testar=True)
            resultado = {"ok": ok, "mensagem": mensagem, "log": log_smtp}
            print(("TESTE OK   " if ok else "TESTE ERRO ") + mensagem, file=sys.stdout, flush=True)
        elif not dados["destinatario"] or "@" not in dados["destinatario"]:
            resultado = {"ok": False, "mensagem": "Informe um e-mail de destino válido.", "log": ""}
        else:
            ok, mensagem, log_smtp = enviar(dados)
            resultado = {"ok": ok, "mensagem": mensagem, "log": log_smtp}
            print(("OK   " if ok else "ERRO ") + mensagem, file=sys.stdout, flush=True)
    tem_senha_salva = bool(dados.get("salvar_senha") and (dados["senha"] or senha_salva))
    dados["senha"] = ""  # nunca devolve a senha para a tela
    return render_template("index.html", d=dados, r=resultado, tem_senha_salva=tem_senha_salva)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
