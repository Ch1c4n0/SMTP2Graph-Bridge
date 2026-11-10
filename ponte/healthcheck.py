"""Verificação de saúde usada pelo Docker: o servidor SMTP está respondendo?"""
import os
import socket
import sys

porta = int(os.environ.get("LISTEN_PORT", "2525"))
try:
    with socket.create_connection(("127.0.0.1", porta), timeout=5) as s:
        saudacao = s.recv(512)
        s.sendall(b"QUIT\r\n")
    sys.exit(0 if saudacao.startswith(b"220") else 1)
except OSError:
    sys.exit(1)
