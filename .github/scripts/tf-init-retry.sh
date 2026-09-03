#!/usr/bin/env bash
# Run `terraform init`, retrying ONLY when it failed for a transient reason.
#
# Why this exists
# ---------------
# `terraform init` reaches out to registry.terraform.io to resolve provider
# versions, and that call fails from GitHub runners often enough to matter. It
# turned main red on 36839bd with:
#
#   Could not retrieve the list of available versions for provider
#   hashicorp/azurerm: could not connect to registry.terraform.io: failed to
#   request discovery document: Get ".../.well-known/terraform.json":
#   read tcp 10.1.1.115:56872->18.154.110.70:443: read: connection reset by peer
#
# on ONE of fourteen Azure validate jobs, on a commit that changed no
# Terraform at all. A red main that nobody can attribute to a change is worse
# than a slow one: the next person either re-runs on faith or starts bisecting
# a phantom.
#
# What it deliberately does NOT do
# --------------------------------
# It does not blanket-retry. A missing variable, a bad provider constraint or a
# syntax error is not going to fix itself, and retrying it three times with
# backoff would triple the time-to-red on the failures that actually matter --
# and make a genuinely flaky config look merely slow. So the output is matched
# against known-transient patterns and anything else fails on the first
# attempt, exactly as before.
#
# Usage: tf-init-retry.sh [extra terraform init args...]
#   Run from the directory to initialise. -backend=false -input=false are
#   always passed; anything given here is appended.

set -uo pipefail

ATTEMPTS="${TF_INIT_ATTEMPTS:-3}"
# 5s then 15s. Registry resets are point-in-time, so a short wait is enough;
# a long one just burns runner minutes.
BACKOFF=(5 15)

# Substrings that mean "the network or the registry misbehaved", never "your
# configuration is wrong". Matched case-insensitively against combined
# stdout+stderr.
TRANSIENT=(
    "could not connect to registry.terraform.io"
    "failed to request discovery document"
    "connection reset by peer"
    "tls handshake timeout"
    "i/o timeout"
    "no such host"
    "unexpected eof"
    "server gave http response to https client"
    "502 bad gateway"
    "503 service unavailable"
    "504 gateway timeout"
    "timeout while waiting for state"
    "error installing provider"
)

is_transient() {
    local hay
    hay="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    local pat
    for pat in "${TRANSIENT[@]}"; do
        case "$hay" in *"$pat"*) return 0 ;; esac
    done
    return 1
}

attempt=0
while :; do
    attempt=$((attempt + 1))
    # Capture to classify the failure, but always replay it so the job log
    # reads exactly as it did before this wrapper existed.
    out="$(terraform init -backend=false -input=false "$@" 2>&1)"
    rc=$?
    printf '%s\n' "$out"

    [ "$rc" -eq 0 ] && exit 0

    if ! is_transient "$out"; then
        printf '\n::error::terraform init failed for a non-transient reason - not retrying.\n' >&2
        exit "$rc"
    fi

    if [ "$attempt" -ge "$ATTEMPTS" ]; then
        printf '\n::error::terraform init still failing after %d attempts; the last failure looked transient (registry or network). If this recurs, check the Terraform registry status before treating it as a config error.\n' "$attempt" >&2
        exit "$rc"
    fi

    wait_for="${BACKOFF[$((attempt - 1))]:-15}"
    printf '\n::warning::terraform init hit a transient registry/network error (attempt %d of %d); retrying in %ds.\n' \
        "$attempt" "$ATTEMPTS" "$wait_for" >&2
    sleep "$wait_for"
done
