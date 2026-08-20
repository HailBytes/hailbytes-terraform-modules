# Phishing-simulation deliverability checklist

A one-page pre-flight for getting simulation mail into the inbox, not the junk
folder or a gateway quarantine. Work top to bottom when onboarding a client, and
re-run the reputation check before each engagement.

Deliverability has three independent layers. All three have to be right; fixing
one does nothing for the others.

## 1. Recipient allow-listing (tell their tenant to trust you)

- [ ] **Exchange Online / Defender** — run the phishing-simulation override.
      This is Microsoft's supported path for third-party sim tools: it skips EOP
      filtering, ZAP, and Safe Links/Attachments detonation, and delivers to the
      Inbox, without a broad transport rule.
      Script: `quickstart/allowlisting/Set-HailBytesPhishSimAllowList.ps1`
      (domains + sending IPs, and optionally the simulation URLs).
- [ ] **Third-party gateway (e.g. TopSec, Mimecast, Proofpoint, Barracuda)** —
      if the client runs a gateway in front of or beside EOP, it does its OWN
      filtering. EOP allow-listing cannot reach it. Allow-list the same domains
      and sending IPs in that product's console too. For smaller gateways with
      no API (e.g. TopSec), this is a manual step on their side — request it in
      writing and confirm before the campaign.

## 2. Sender authentication (prove the mail is really from you)

- [ ] **SPF** — the sending IP / relay is authorised in the sending domain's SPF
      record.
- [ ] **DKIM** — the sending domain signs, and the signature validates.
- [ ] **DMARC** — a policy exists and SPF/DKIM align with the From domain.
      Misalignment here is a common silent cause of junk-foldering even when the
      IP is clean and the tenant allow-listed.

## 3. Sender reputation (make sure you're not already blocked)

- [ ] **Blocklist check** — run `check-sender-reputation.sh <sending-ip>` at
      onboarding and before each engagement. It checks Spamhaus ZEN, Barracuda
      and SpamCop.
      - A recipient allow-list does NOT override a connection-time blocklist
        check: a gateway can reject a Spamhaus-listed IP before any allow-list is
        consulted.
      - If the script reports **indeterminate** for a list, it could not query it
        from that resolver (Spamhaus refuses large public resolvers such as
        8.8.8.8). Re-check from a host on its own provider's resolver, via the
        Spamhaus DQS, or at https://check.spamhaus.org — do not assume clean.
- [ ] **If listed** — request delisting through the blocklist's site, and fix the
      cause first (open relay, compromised host, cold IP sending volume) or it
      relists. For a self-hosted SAT VM, prefer a dedicated, warmed sending IP or
      an authenticated relay with existing reputation over the VM's raw egress IP.

## Quick reference

| Symptom | Most likely layer |
|---|---|
| Mail lands in Junk | Authentication (SPF/DKIM/DMARC) or EOP allow-list missing |
| Mail never arrives, no bounce | Gateway quarantine (layer 1, third-party) |
| Connection rejected / bounced at send | Reputation (blocklist) |
| Delivered but images broken | Not deliverability — see hailbytes-sat `docs/EMAIL_TEMPLATE_IMAGES.md` (use `cid:`, not `data:`) |
