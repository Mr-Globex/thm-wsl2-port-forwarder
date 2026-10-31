# THM -> WSL2 Port Forwarding Refresher

A PowerShell script that forwards ports from your **TryHackMe OpenVPN adapter** on a Windows host into a **WSL2 distro** (e.g. Kali), so reverse shells and file transfers from target machines reach your listener inside WSL2.

By **GLOBEX** | [TryHackMe profile](https://tryhackme.com/p/GLOBEX)

## Why this exists

Targets on TryHackMe can only talk to your Windows host's VPN IP, but your listener (`nc`, Metasploit, etc.) runs inside WSL2, which sits behind NAT with an IP that changes every time WSL restarts. This script rebuilds the `netsh interface portproxy` rules and matching firewall rules with the current VPN and WSL2 IPs.

## Requirements

- Windows 10/11 with WSL2 and a distro installed (tested with Kali on Windows 10 x64)
- TryHackMe OpenVPN connected (TAP adapter up)
- PowerShell running **as Administrator**

## Setup

1. Get the script:

   ```powershell
   git clone https://github.com/Mr-Globex/thm-wsl2-port-forwarder.git
   cd thm-wsl2-port-forwarder
   ```

   No git? Download the ZIP from the green **Code** button, extract it, then unblock the script:

   ```powershell
   Unblock-File .\Refresh_THM_Port-Forwarding.ps1
   ```
   
2. Find the values you may need to change:

   | Setting | How to find it | Default |
   |---|---|---|
   | `-LabSubnet` | Subnet of the target machines (`route print` while on the VPN, or the IP of a target), in CIDR form, e.g. `10.10.0.0/16` | none (required) |
   | `-VpnAlias` | `Get-NetAdapter` | `OpenVPN TAP-Windows6` |
   | `-Distro` | `wsl.exe -l -v` | your default distro |

3. If scripts are blocked, allow them for the current session only:

   ```powershell
   Set-ExecutionPolicy Bypass -Scope Process
   ```

## Usage

```powershell
# Forward ports 4444 and 8000
.\Refresh_THM_Port-Forwarding.ps1 -Ports 4444,8000 -LabSubnet 10.10.0.0/16

# Target a specific distro
.\Refresh_THM_Port-Forwarding.ps1 -Ports 4444 -LabSubnet 10.10.0.0/16 -Distro kali-linux

# Remove the rules when you're done
.\Refresh_THM_Port-Forwarding.ps1 -Ports 4444,8000 -Remove
```

Re-run it whenever you reconnect the VPN or restart WSL.

Then start your listener in WSL and point your payload at the **VPN IP** the script prints, not the WSL IP.

## What it does

1. Detects your current VPN IPv4 address.
2. Detects your current WSL2 IP.
3. Removes any stale portproxy rule for each port.
4. Adds `VPN IP:port -> WSL IP:port`.
5. Recreates an inbound firewall rule allowing only `-LabSubnet` to reach that port.

## Caveats

- TCP only.
- Ports are forwarded 1:1 (same port on both sides).
- Removing existing rules is per port number: any portproxy rule listening on a given port is replaced, whatever its listen address.
- Keep the file ASCII-only if you edit it; Windows PowerShell 5.1 can misread non-ASCII characters in scripts saved without a BOM.

## Notes & troubleshooting

- `-VpnAlias` expects the adapter's **Name** from `Get-NetAdapter` (not the description). Newer OpenVPN installs may name it differently, e.g. "OpenVPN Wintun".
- Your listener will see connections coming from the Windows host, not the target's real IP. That's expected with portproxy.
- Metasploit: keep `LHOST` as the VPN IP printed by the script, and set `ReverseListenerBindAddress 0.0.0.0` so the handler can bind inside WSL.
- Portproxy needs the **IP Helper** service (`iphlpsvc`) running.
- THM target subnets differ by region/room. Check your target's IP and set `-LabSubnet` to match.

## Disclaimer

Intended for authorized lab and training environments such as TryHackMe. The script opens inbound ports on your host (restricted to the lab subnet). Use `-Remove` when finished. You are responsible for how you use it.
