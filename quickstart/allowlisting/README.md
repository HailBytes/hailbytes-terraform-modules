# Recipient allow-listing for phishing simulations

Client-facing scripts for getting authorised simulation mail past the
recipient's email security. Run with the client's explicit authorisation.

| File | Platform | What it does |
|------|----------|--------------|
| `Set-HailBytesPhishSimAllowList.ps1` | Exchange Online / Microsoft Defender for Office 365 | Configures the Advanced Delivery **phishing-simulation override** for your sending domains + IPs (and optionally the simulation URLs). Skips EOP filtering, ZAP, and Safe Links/Attachments detonation, and delivers to the Inbox — without a broad transport rule. Idempotent. |

Third-party gateways (TopSec, Mimecast, Proofpoint, Barracuda, …) that sit in
front of or beside Exchange Online do their own filtering and must be
allow-listed in **their** console too — EOP allow-listing cannot reach them.

Allow-listing is only one of three deliverability layers. See
[../../docs/DELIVERABILITY_CHECKLIST.md](../../docs/DELIVERABILITY_CHECKLIST.md)
for the full picture (authentication and sender reputation are the other two),
and `../check-sender-reputation.sh` for the reputation check.

## Usage

```powershell
./Set-HailBytesPhishSimAllowList.ps1 `
    -SendingDomains "phish-yourco.com","training.yourco.com" `
    -SendingIpRanges "20.51.0.42","203.0.113.0/28" `
    -SimulationUrls "phish-yourco.com/*"
```

Requires the Security Administrator (or Global Admin) role and the
`ExchangeOnlineManagement` module (installed automatically if absent). Runs in
Azure Cloud Shell (PowerShell) or any workstation with PowerShell.
