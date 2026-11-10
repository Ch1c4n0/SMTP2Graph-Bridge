VAULT AUTO-UNSEAL (OPTIONAL / OPCIONAL)
=======================================

EN: If you choose auto-unseal in scripts\2-configurar-vault.ps1, the file
    unseal.key is saved here. The "vault-unseal" container uses it to unlock
    Vault automatically after every restart.
    Trade-off: anyone who can read this folder (and the Docker volume) can
    unlock Vault. Restrict NTFS permissions on D:\SMTP2Graph.
    Without this file, you must unseal manually after each restart
    (script option 2).

PT: Se você escolher o auto-unseal no scripts\2-configurar-vault.ps1, o
    arquivo unseal.key é salvo aqui. O container "vault-unseal" usa esse
    arquivo para desbloquear o Vault sozinho depois de cada reinício.
    Atenção: quem conseguir ler esta pasta (e o volume do Docker) consegue
    desbloquear o Vault. Restrinja as permissões NTFS de D:\SMTP2Graph.
    Sem este arquivo, você precisa desbloquear manualmente após cada
    reinício (opção 2 do script).
