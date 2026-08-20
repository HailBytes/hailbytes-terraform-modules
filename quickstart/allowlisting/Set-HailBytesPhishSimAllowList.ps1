<#
.SYNOPSIS
  Allow-list HailBytes SAT phishing-simulation mail in Exchange Online / Microsoft
  Defender for Office 365, the way Microsoft intends for third-party sim tools.

.DESCRIPTION
  Runs in Azure Cloud Shell (PowerShell) or any workstation with the
  ExchangeOnlineManagement module. It configures the Advanced Delivery
  "phishing simulation" override, which tells Defender that mail from the given
  domains and sending IPs is an authorised simulation. That override:

    * skips EOP spam/phish filtering and zero-hour auto purge (ZAP),
    * skips Safe Links / Safe Attachments detonation of the sim payload,
    * and delivers to the Inbox rather than Junk,

  WITHOUT a broad transport (mail-flow) rule that would over-allow real mail.
  This is the supported path and does not weaken filtering for anything else.

  It is idempotent: re-running ADDS any missing domains/IPs to the existing
  rule rather than duplicating it.

.PARAMETER SendingDomains
  The domain(s) your simulations send FROM (the envelope/header From domains you
  use in HailBytes SAT sending profiles). 1-20 entries.

.PARAMETER SendingIpRanges
  The public IP(s) the simulation sends from — the egress IP of the HailBytes
  SAT VM, or your SMTP relay's IP. Single IP, CIDR, or low-high range.

.PARAMETER SimulationUrls
  Optional. Landing-page / tracking URLs to allow so Safe Links does not rewrite
  or block them. Wildcards allowed, e.g. "phish.example.com/*".

.EXAMPLE
  ./Set-HailBytesPhishSimAllowList.ps1 `
      -SendingDomains "phish-yourco.com","training.yourco.com" `
      -SendingIpRanges "20.51.0.42","203.0.113.0/28" `
      -SimulationUrls "phish-yourco.com/*"

.NOTES
  Requires: the "Security Administrator" (or Global Admin) role, and the
  ExchangeOnlineManagement module (installed automatically if absent).

  This covers Exchange Online / Defender ONLY. If a client runs a third-party
  gateway IN FRONT OF or BESIDE EOP (e.g. TopSec), it must ALSO be allow-listed
  in that product's own console — this script cannot reach it. See the notes
  printed at the end.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateCount(1, 20)]
    [string[]] $SendingDomains,

    [Parameter(Mandatory = $true)]
    [ValidateCount(1, 10)]
    [string[]] $SendingIpRanges,

    [Parameter(Mandatory = $false)]
    [string[]] $SimulationUrls = @()
)

$ErrorActionPreference = 'Stop'

# The Advanced Delivery policy is a singleton and MUST carry this exact name.
$PolicyName = 'PhishSimOverridePolicy'
$RuleName   = 'HailBytes SAT phishing simulation'

Write-Host '==> Ensuring ExchangeOnlineManagement module is available'
if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force -AllowClobber
}
Import-Module ExchangeOnlineManagement

Write-Host '==> Connecting to Exchange Online (a sign-in window/prompt will appear)'
Connect-ExchangeOnline -ShowBanner:$false

try {
    # ----- 1. The override POLICY (enables the feature; one per tenant) -----
    $policy = Get-PhishSimOverridePolicy -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -eq $PolicyName }
    if ($null -eq $policy) {
        Write-Host "==> Creating phishing-simulation override policy"
        New-PhishSimOverridePolicy -Name $PolicyName | Out-Null
    } else {
        Write-Host "==> Override policy already exists"
        if ($policy.Enabled -ne $true) {
            Set-PhishSimOverridePolicy -Identity $PolicyName -Enabled $true | Out-Null
            Write-Host "    (re-enabled it)"
        }
    }

    # ----- 2. The override RULE (carries the domains + sending IPs) -----
    $rule = Get-ExoPhishSimOverrideRule -ErrorAction SilentlyContinue |
            Where-Object { $_.Policy -eq $PolicyName } | Select-Object -First 1

    if ($null -eq $rule) {
        Write-Host "==> Creating override rule with your domains and sending IPs"
        New-ExoPhishSimOverrideRule `
            -Name $RuleName `
            -Policy $PolicyName `
            -Domains $SendingDomains `
            -SenderIpRanges $SendingIpRanges | Out-Null
    } else {
        # Idempotent: add only what is missing.
        Write-Host "==> Override rule exists; adding any missing domains/IPs"
        $existingDomains = @($rule.Domains)
        $existingIps     = @($rule.SenderIpRanges)

        $addDomains = $SendingDomains | Where-Object { $existingDomains -notcontains $_ }
        $addIps     = $SendingIpRanges | Where-Object { $existingIps -notcontains $_ }

        if ($addDomains -or $addIps) {
            $params = @{ Identity = $rule.Identity }
            if ($addDomains) { $params['AddDomains'] = $addDomains }
            if ($addIps)     { $params['AddSenderIpRanges'] = $addIps }
            Set-ExoPhishSimOverrideRule @params | Out-Null
            if ($addDomains) { Write-Host "    added domains: $($addDomains -join ', ')" }
            if ($addIps)     { Write-Host "    added IPs:     $($addIps -join ', ')" }
        } else {
            Write-Host "    nothing to add — already covers your domains and IPs"
        }
    }

    # ----- 3. Optional: allow the simulation URLs (Tenant Allow/Block List) -----
    # Safe Links can still rewrite/warn on the landing-page URL even when the
    # message itself is allowed, so allow the URLs explicitly if supplied.
    foreach ($url in $SimulationUrls) {
        $already = Get-TenantAllowBlockListItems -ListType Url -ErrorAction SilentlyContinue |
                   Where-Object { $_.Value -eq $url }
        if ($null -eq $already) {
            Write-Host "==> Allow-listing simulation URL: $url"
            New-TenantAllowBlockListItems -ListType Url -Allow -Entries $url `
                -Notes 'HailBytes SAT phishing simulation' -NoExpiration | Out-Null
        } else {
            Write-Host "==> URL already allow-listed: $url"
        }
    }

    # ----- 4. Show the resulting state -----
    Write-Host ''
    Write-Host '===================== Result ====================='
    $r = Get-ExoPhishSimOverrideRule | Where-Object { $_.Policy -eq $PolicyName } | Select-Object -First 1
    Write-Host "Policy   : $PolicyName  (Enabled: $((Get-PhishSimOverridePolicy | Where-Object Name -eq $PolicyName).Enabled))"
    Write-Host "Rule     : $($r.Name)"
    Write-Host "Domains  : $($r.Domains -join ', ')"
    Write-Host "SendIPs  : $($r.SenderIpRanges -join ', ')"
    if ($SimulationUrls) { Write-Host "URLs     : $($SimulationUrls -join ', ')" }
    Write-Host '=================================================='
}
finally {
    Disconnect-ExchangeOnline -Confirm:$false | Out-Null
}

Write-Host ''
Write-Host 'Done. Two things this script CANNOT do for you:'
Write-Host ''
Write-Host '  1. Third-party gateways (e.g. TopSec). If mail is filtered by a'
Write-Host '     product in front of or beside EOP, allow-list the same domains'
Write-Host '     and sending IPs in THAT product''s console too. EOP allow-listing'
Write-Host '     alone will not stop a separate gateway from quarantining the mail.'
Write-Host ''
Write-Host '  2. Sender reputation (e.g. Spamhaus). This override tells the'
Write-Host '     RECIPIENT tenant to trust you; it does nothing about your SENDING'
Write-Host '     IP''s reputation. If the sending IP is on a Spamhaus list, gateways'
Write-Host '     that check at connection time can still reject before EOP runs.'
Write-Host '     Check the IP at https://check.spamhaus.org, keep SPF/DKIM/DMARC'
Write-Host '     aligned for the sending domain, and request delisting if needed.'
