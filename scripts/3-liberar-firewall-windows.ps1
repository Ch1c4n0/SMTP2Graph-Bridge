<#
.SYNOPSIS
  Libera a porta 25 (SMTP da ponte) no Firewall do Windows SOMENTE para a sua rede interna.

.COMO USAR
  1. Abra o PowerShell COMO ADMINISTRADOR
     (Menu Iniciar > digite PowerShell > botão direito > Executar como administrador)
  2. cd D:\SMTP2Graph\scripts
  3. .\3-liberar-firewall-windows.ps1 -RedeOrigem "192.168.0.0/24"

  Troque 192.168.0.0/24 pela faixa da sua rede. Para liberar só UMA máquina
  (a da aplicação), use o IP dela, ex.: -RedeOrigem "192.168.0.80"
#>
param(
    [Parameter(Mandatory = $true)][string]$RedeOrigem,
    [int]$Porta = 25
)

$ErrorActionPreference = "Stop"
$nome = "SMTP2Graph - SMTP porta $Porta (rede interna)"

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Abra o PowerShell como ADMINISTRADOR e rode de novo." -ForegroundColor Red
    exit 1
}

Get-NetFirewallRule -DisplayName $nome -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $nome -Direction Inbound -Protocol TCP -LocalPort $Porta `
    -RemoteAddress $RedeOrigem -Action Allow -Profile Domain, Private | Out-Null
Write-Host "Regra criada: porta $Porta liberada somente para $RedeOrigem" -ForegroundColor Green

# O Docker Desktop costuma criar regras próprias que liberam o programa dele para qualquer origem.
Write-Host "`nRegras do Docker Desktop encontradas (confira se alguma libera para 'Any'/'Qualquer'):" -ForegroundColor Yellow
Get-NetFirewallRule -Direction Inbound -Enabled True -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match "Docker" } |
    ForEach-Object {
        $f = $_ | Get-NetFirewallAddressFilter
        [PSCustomObject]@{ Regra = $_.DisplayName; Acao = $_.Action; Perfil = $_.Profile; Origem = $f.RemoteAddress }
    } | Format-Table -AutoSize

Write-Host "Se alguma regra do Docker estiver com Origem = Any e Acao = Allow, a porta pode ficar"
Write-Host "aberta para qualquer origem. Por isso: mantenha SEMPRE o usuário/senha SMTP ligado no .env"
Write-Host "e nunca encaminhe (port forward) a porta 25 no roteador para esta máquina.`n"
