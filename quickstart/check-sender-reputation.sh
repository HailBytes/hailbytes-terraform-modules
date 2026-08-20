#!/usr/bin/env bash
# HailBytes SAT — sender-reputation preflight.
#
# Checks the public IP(s) your phishing simulations send FROM against the major
# DNS blocklists (Spamhaus and friends). Run it at onboarding, and again after
# any change to the sending path, BEFORE a client campaign.
#
# Runs anywhere with bash + host/dig (Azure Cloud Shell has both). It queries
# public DNSBLs only; it sends no mail and needs no credentials.
#
#   ./check-sender-reputation.sh 20.51.0.42 203.0.113.7
#   ./check-sender-reputation.sh                 # auto-detects this host's egress IP
#
# Exit codes: 0 = all clean, 1 = at least one IP is listed, 2 = usage/lookup error.
#
# WHY THIS MATTERS
# A recipient-side allow-list (EOP advanced delivery, a gateway rule) tells the
# RECIPIENT to trust you. It does nothing about your SENDING IP's reputation. If
# the IP is on a Spamhaus list, a gateway that checks at connection time can
# reject before any allow-list is consulted. This catches that before a client
# does.
set -uo pipefail

# name -> DNSBL zone. Spamhaus ZEN rolls up SBL/CSS/XBL/PBL in one query.
BLOCKLISTS=(
    "Spamhaus ZEN|zen.spamhaus.org"
    "Barracuda|b.barracudacentral.org"
    "SpamCop|bl.spamcop.net"
)

lookup_tool() {
    if command -v dig >/dev/null 2>&1; then echo dig
    elif command -v host >/dev/null 2>&1; then echo host
    else echo ""; fi
}

TOOL="$(lookup_tool)"
if [ -z "$TOOL" ]; then
    echo "ERROR: neither dig nor host is available for DNS lookups." >&2
    exit 2
fi

# Collect target IPs: arguments, or this host's egress IP if none given.
IPS=("$@")
if [ ${#IPS[@]} -eq 0 ]; then
    echo "No IP given; detecting this host's egress IP..."
    egress="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
    if [ -z "$egress" ]; then
        echo "ERROR: could not detect egress IP; pass the sending IP(s) explicitly." >&2
        exit 2
    fi
    echo "Egress IP: ${egress}"
    IPS=("$egress")
fi

# Reverse the octets of an IPv4 address for a DNSBL query.
reverse_ip() {
    local IFS=.
    # shellcheck disable=SC2086
    set -- $1
    echo "$4.$3.$2.$1"
}

# Classify a DNSBL answer. Echoes: listed | clean | indeterminate
#
# The indeterminate case is not paranoia. Spamhaus (and some others) REFUSE
# queries that arrive via a large public resolver -- e.g. 8.8.8.8, which is what
# many cloud shells use -- and signal it with a return code in 127.255.255.0/24
# (…252 typo, …254 public/open resolver, …255 rate limited). An empty answer
# means "not listed"; a 127.255.255.x answer means "we could not actually check"
# and must NEVER be reported as clean.
classify_dnsbl() {
    local query="$1" answer
    if [ "$TOOL" = "dig" ]; then
        answer="$(dig +short +time=3 +tries=1 A "$query" 2>/dev/null)"
    else
        answer="$(host -W 3 "$query" 2>/dev/null | awk '/has address/ {print $NF}')"
    fi
    if [ -z "$answer" ]; then
        echo clean
    elif echo "$answer" | grep -q '^127\.255\.255\.'; then
        echo indeterminate
    else
        echo listed
    fi
}

any_listed=0
any_indeterminate=0

# Positive control per zone. 127.0.0.2 is the universal DNSBL test entry and
# MUST classify as "listed" on a working zone. If it doesn't, this resolver
# cannot see that zone -- Spamhaus in particular answers NXDOMAIN (not an error
# code) to queries from large public resolvers, which is indistinguishable from
# a real "not listed" without this control. Zones that fail the control are
# marked unusable, and real lookups against them are reported indeterminate
# rather than clean.
declare -A ZONE_USABLE=()
echo "Checking blocklist reachability from this resolver (${TOOL})..."
for entry in "${BLOCKLISTS[@]}"; do
    name="${entry%%|*}"
    zone="${entry##*|}"
    if [ "$(classify_dnsbl "2.0.0.127.${zone}")" = "listed" ]; then
        ZONE_USABLE["$zone"]=1
        printf '  %-14s reachable\n' "$name"
    else
        ZONE_USABLE["$zone"]=0
        printf '  %-14s UNREACHABLE from here\n' "$name"
    fi
done
echo

for ip in "${IPS[@]}"; do
    if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "  SKIP ${ip} — not an IPv4 address (DNSBL checks are IPv4-only here)"
        continue
    fi
    rev="$(reverse_ip "$ip")"
    echo "=============================================================="
    echo " ${ip}"
    echo "=============================================================="
    for entry in "${BLOCKLISTS[@]}"; do
        name="${entry%%|*}"
        zone="${entry##*|}"
        if [ "${ZONE_USABLE[$zone]}" -ne 1 ]; then
            printf '  %-14s indeterminate (list unreachable from this resolver)\n' "$name"
            any_indeterminate=1
            continue
        fi
        case "$(classify_dnsbl "${rev}.${zone}")" in
            listed)
                printf '  %-14s LISTED\n' "$name"
                any_listed=1
                ;;
            indeterminate)
                printf '  %-14s indeterminate (resolver refused — see note)\n' "$name"
                any_indeterminate=1
                ;;
            *)
                printf '  %-14s clean\n' "$name"
                ;;
        esac
    done
    echo
done

if [ "$any_listed" -eq 1 ]; then
    echo "At least one sending IP is on a blocklist. Deliverability will suffer"
    echo "until it is remediated. See the onboarding deliverability checklist:"
    echo "  request delisting, confirm SPF/DKIM/DMARC alignment, and consider a"
    echo "  dedicated warmed sending IP or relay."
    exit 1
fi

if [ "${any_indeterminate:-0}" -eq 1 ]; then
    echo "Some lists could not be queried from here (resolver refused). Spamhaus"
    echo "refuses lookups via large public resolvers such as 8.8.8.8, which many"
    echo "cloud shells use. Re-check those from a host using its provider's own"
    echo "resolver, or use the free Spamhaus Data Query Service (DQS) with a key,"
    echo "or the web form at https://check.spamhaus.org. Do NOT read the above as"
    echo "clean for an indeterminate list."
    exit 1
fi

echo "All checked IPs are clean on the queried blocklists."
echo "Reputation is not static -- re-run before each client engagement."
