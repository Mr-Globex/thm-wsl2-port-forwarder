<#
.SYNOPSIS
    Refreshes port forwarding from the TryHackMe OpenVPN adapter into a WSL2 distro (e.g. Kali).

.DESCRIPTION
    Problem this solves:
      Target machines on TryHackMe can only reach your Windows host's VPN (TAP) IP.
      Your reverse-shell listener, however, runs inside WSL2, which sits behind a NAT
      with an IP that CHANGES on every WSL restart / reboot.

    What this script does, for every port you give it:
      1. Finds your current TryHackMe VPN IPv4 address (the OpenVPN TAP adapter).
      2. Finds the current IP of your WSL2 distro.
      3. Removes any old netsh portproxy rule for that port.
      4. Creates a fresh portproxy rule:  <VPN IP>:<port>  ->  <WSL IP>:<port>
      5. Recreates a Windows Firewall inbound rule that only allows the lab subnet.

    Run it again whenever you reconnect the VPN or restart WSL.

.PARAMETER Ports
    One or more TCP ports to forward (the same port is used on both sides).
    Example: 4444,8000,9001

.PARAMETER LabSubnet
    REQUIRED. The subnet your target machines live in, used as the firewall's
    "remote address" so only the lab can reach the forwarded ports.
    Look at your VPN routes / target IPs to find it (e.g. run `route print` while
    connected, or check the IP of a THM machine). CIDR notation, e.g. 10.10.0.0/16.

.PARAMETER VpnAlias
    Name of the VPN network adapter. Default is the standard OpenVPN TAP adapter.
    Find yours with:  Get-NetAdapter | Select-Object Name, InterfaceDescription, Status

.PARAMETER Distro
    Name of the WSL distro to forward to. Leave empty to use your default distro.
    List yours with:  wsl.exe -l -v

.PARAMETER Remove
    Delete the portproxy and firewall rules for the given ports instead of creating them.
    Use this to clean up when you're done.

.EXAMPLE
    .\Refresh_THM_Port-Forwarding.ps1 -Ports 4444,8000 -LabSubnet 10.10.0.0/16

.EXAMPLE
    .\Refresh_THM_Port-Forwarding.ps1 -Ports 4444 -LabSubnet 10.10.0.0/16 -Distro kali-linux

.EXAMPLE
    .\Refresh_THM_Port-Forwarding.ps1 -Ports 4444,8000 -Remove

.NOTES
    Author       : GLOBEX
    TryHackMe    : https://tryhackme.com/p/GLOBEX
    Requirements : Windows 10/11, WSL2, TryHackMe OpenVPN connected, PowerShell run as Administrator
    Intended use : Authorized lab / training environments only (e.g. TryHackMe).
                   This opens inbound ports on your host. Run -Remove when finished.
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateRange(1, 65535)]
    [int[]]$Ports,

    # >>> EDIT ME: your lab subnet in CIDR form (see .PARAMETER LabSubnet above) <<<
    [string]$LabSubnet = '<LAB_SUBNET_CIDR>',

    # >>> EDIT ME if your VPN adapter has a different name <<<
    [string]$VpnAlias = 'OpenVPN TAP-Windows6',

    # >>> EDIT ME if you don't want your default WSL distro (e.g. 'kali-linux') <<<
    [string]$Distro = '',

    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "  ====================================================" -ForegroundColor Cyan
Write-Host "   THM -> WSL2 Port Forwarding Refresher" -ForegroundColor Cyan
Write-Host "   by GLOBEX  |  https://tryhackme.com/p/GLOBEX" -ForegroundColor Cyan
Write-Host "  ====================================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# Helper: remove every portproxy rule that listens on a given port
# (regardless of which listen IP it was bound to, so stale rules from an
#  old VPN IP don't pile up)
# ---------------------------------------------------------------------------
function Remove-PortProxyRule {
    param([int]$Port)

    $Rules = & netsh interface portproxy show v4tov4
    foreach ($Line in $Rules) {
        # Table rows look like:  <listen addr>  <listen port>  <connect addr>  <connect port>
        if ($Line -match '^\s*(\d{1,3}(?:\.\d{1,3}){3})\s+(\d+)\s+(\d{1,3}(?:\.\d{1,3}){3})\s+(\d+)\s*$') {
            $ListenIP   = $Matches[1]
            $ListenPort = [int]$Matches[2]

            if ($ListenPort -eq $Port) {
                & netsh interface portproxy delete v4tov4 `
                    "listenaddress=$ListenIP" "listenport=$Port" | Out-Null
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Helper: remove the firewall rule this script manages for a given port
# ---------------------------------------------------------------------------
function Remove-ManagedFirewallRule {
    param([string]$Name)

    Get-NetFirewallRule -DisplayName $Name -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule
}

# ---------------------------------------------------------------------------
# -Remove mode: clean up and exit
# ---------------------------------------------------------------------------
if ($Remove) {
    foreach ($Port in $Ports) {
        Write-Host "[-] Removing rules for port $Port" -ForegroundColor Cyan
        Remove-PortProxyRule -Port $Port
        Remove-ManagedFirewallRule -Name "TryHackMe VPN to WSL2 - TCP $Port"
    }

    Write-Host "`n--- Current Active Port Forwarding Table ---" -ForegroundColor Yellow
    & netsh interface portproxy show v4tov4
    return
}

# ---------------------------------------------------------------------------
# Sanity check: make sure the placeholder was replaced
# ---------------------------------------------------------------------------
if ($LabSubnet -like '<*>') {
    throw "Set -LabSubnet to your lab subnet in CIDR form (e.g. -LabSubnet 10.10.0.0/16), or edit the default at the top of the script."
}

# ---------------------------------------------------------------------------
# Step 1: current VPN IPv4 address (ignore APIPA 169.254.x.x leftovers)
# ---------------------------------------------------------------------------
$VpnIP = Get-NetIPAddress -InterfaceAlias $VpnAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '169.254.*' } |
    Select-Object -First 1 -ExpandProperty IPAddress

if (-not $VpnIP) {
    throw "No IPv4 address found on adapter '$VpnAlias'. Is OpenVPN connected? (List adapters with: Get-NetAdapter)"
}

# ---------------------------------------------------------------------------
# Step 2: current WSL2 IP (changes after every WSL restart, hence this script)
# `hostname -I` can return several addresses; we take the first one.
# ---------------------------------------------------------------------------
if ($Distro) {
    $WslOutput = (& wsl.exe -d $Distro hostname -I)
} else {
    $WslOutput = (& wsl.exe hostname -I)
}
$WslOutput = ($WslOutput | Out-String).Trim()
$WslIP = ($WslOutput -split '\s+')[0]

if ($WslIP -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
    throw "Could not determine the WSL IP. Check that your distro is installed and running (wsl.exe -l -v)."
}

Write-Host "VPN IP : $VpnIP" -ForegroundColor Yellow
Write-Host "WSL IP : $WslIP" -ForegroundColor Yellow
Write-Host "Subnet : $LabSubnet (allowed to reach forwarded ports)" -ForegroundColor Yellow

# ---------------------------------------------------------------------------
# Step 3-5: for each port, replace the portproxy rule and firewall rule
# ---------------------------------------------------------------------------
foreach ($Port in $Ports) {
    Write-Host "`n[+] Processing port: $Port" -ForegroundColor Cyan
    $FirewallRule = "TryHackMe VPN to WSL2 - TCP $Port"

    # Drop any old rule for this port (e.g. bound to a previous VPN IP)
    Remove-PortProxyRule -Port $Port

    # Forward <VPN IP>:<port> -> <WSL IP>:<port>
    & netsh interface portproxy add v4tov4 `
        "listenaddress=$VpnIP" "listenport=$Port" `
        "connectaddress=$WslIP" "connectport=$Port"

    if ($LASTEXITCODE -ne 0) {
        throw "Could not create the portproxy rule for port $Port."
    }

    # Recreate the firewall rule: inbound TCP on the VPN IP, from the lab subnet only
    Remove-ManagedFirewallRule -Name $FirewallRule

    New-NetFirewallRule `
        -DisplayName   $FirewallRule `
        -Direction     Inbound `
        -Action        Allow `
        -Protocol      TCP `
        -LocalAddress  $VpnIP `
        -LocalPort     $Port `
        -RemoteAddress $LabSubnet `
        -Profile       Any | Out-Null

    Write-Host "    -> Port $Port forwarding refreshed successfully." -ForegroundColor Green
}

Write-Host "`n--- Current Active Port Forwarding Table ---" -ForegroundColor Yellow
& netsh interface portproxy show v4tov4

Write-Host "`nReminder: start your listener in WSL (e.g. nc -lvnp <port>) and point your payload at $VpnIP." -ForegroundColor DarkGray
Write-Host "When you're done, clean up with: .\Refresh_THM_Port-Forwarding.ps1 -Ports <ports> -Remove" -ForegroundColor DarkGray
