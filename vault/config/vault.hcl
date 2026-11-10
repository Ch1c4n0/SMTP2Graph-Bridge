# ---------------------------------------------------------------
# HashiCorp Vault - configuração do servidor
# Vault server configuration
# ---------------------------------------------------------------

# Interface web: http://127.0.0.1:8200/ui (só a partir desta máquina / only from this machine)
ui = true

# Armazenamento integrado (Raft), gravado no volume Docker "vault-data"
# Integrated storage (Raft), persisted in the "vault-data" Docker volume
storage "raft" {
  path    = "/vault/file"
  node_id = "smtp2graph-vault-1"
}

# Recomendado com Raft / Recommended with Raft
disable_mlock = true

# O Vault só é acessível pela rede interna do Docker e por 127.0.0.1 (veja docker-compose.yml).
# Vault is only reachable on the internal Docker network and on 127.0.0.1 (see docker-compose.yml).
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

api_addr     = "http://vault:8200"
cluster_addr = "http://vault:8201"
