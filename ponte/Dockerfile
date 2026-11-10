# ---------------------------------------------------------------
# Imagem da ponte SMTP -> Microsoft Graph
# ---------------------------------------------------------------
FROM python:3.12-slim

# Mostra os logs na hora (sem guardar em buffer) e não cria arquivos .pyc
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# Instala as bibliotecas primeiro (o Docker reaproveita essa etapa nas próximas builds)
COPY requirements.txt .
RUN pip install -r requirements.txt

COPY smtp2graph.py healthcheck.py ./

# Roda como usuário comum (sem poderes de administrador), por segurança
RUN useradd --system --uid 10001 --no-create-home ponte
USER ponte

# Porta interna do container (no seu computador ela é ligada à porta 25)
EXPOSE 2525

# O Docker testa a cada 30s se o SMTP está respondendo
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
  CMD ["python", "healthcheck.py"]

CMD ["python", "smtp2graph.py"]
