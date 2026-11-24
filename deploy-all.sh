#!/usr/bin/env bash
# Deploys all three services to Floci in the right order, with ONE shared TOKEN_SECRET.
# (Three different secrets was the first bug we hit: services then reject each other's tokens.)
#
#   Git Bash, from this folder, with Floci running:   bash deploy-all.sh
#
# What it does:
#   1. creates infra/deploy.env in each service (git-ignored) if missing
#   2. puts the SAME random TOKEN_SECRET in all three, and an INVITE_CODE in campaign-service
#   3. runs each service's own infra/deploy.sh: campaign, donation-progress, pledge
# Safe to run again: it keeps the secret and invite code already in campaign-service/infra/deploy.env.
# Set DRY_RUN=1 to only prepare the deploy.env files without deploying.
set -euo pipefail
cd "$(dirname "$0")"
export AWS_PROFILE="${AWS_PROFILE:-floci}"
export MSYS_NO_PATHCONV=1

SERVICES=(campaign-service donation-progress-service pledge-service)
CAMP=campaign-service/infra/deploy.env
rand() { node -e "console.log(require('crypto').randomBytes($1).toString('hex'))"; }

for s in "${SERVICES[@]}"; do
  [ -f "$s/package.json" ] || { echo "Run this from the folder that contains $s/"; exit 1; }
  [ -f "$s/infra/deploy.env" ] || cp "$s/infra/deploy.env.example" "$s/infra/deploy.env"
  sed -i 's/\r$//' "$s/infra/deploy.env"          # Windows editors add \r; it would make secrets differ
done

SECRET=$(grep '^TOKEN_SECRET=' "$CAMP" | cut -d= -f2- || true)
[ -n "$SECRET" ] || SECRET=$(rand 32)
INVITE=$(grep '^INVITE_CODE=' "$CAMP" | cut -d= -f2- || true)
[ -n "$INVITE" ] || INVITE="team37-$(rand 4)"

set_var() { # file name value  (replace the line, or add it)
  if grep -q "^$2=" "$1"; then sed -i "s|^$2=.*|$2=$3|" "$1"; else printf '%s=%s\n' "$2" "$3" >> "$1"; fi
}
for s in "${SERVICES[@]}"; do set_var "$s/infra/deploy.env" TOKEN_SECRET "$SECRET"; done
set_var "$CAMP" INVITE_CODE "$INVITE"

# The three secrets must be byte-identical. Print only a short fingerprint, never the secret.
echo "TOKEN_SECRET fingerprints (must be identical):"
for s in "${SERVICES[@]}"; do
  printf '  %-28s %s\n' "$s" "$(grep '^TOKEN_SECRET=' "$s/infra/deploy.env" | sha256sum | cut -c1-8)"
done
[ "$(for s in "${SERVICES[@]}"; do grep '^TOKEN_SECRET=' "$s/infra/deploy.env"; done | sort -u | wc -l)" -eq 1 ] \
  || { echo "Secrets differ, stopping."; exit 1; }

if [ "${DRY_RUN:-0}" = "1" ]; then echo "DRY_RUN: deploy.env files are ready, nothing deployed."; exit 0; fi

for s in "${SERVICES[@]}"; do
  echo; echo "################  $s  ################"
  (cd "$s" && npm install --no-audit --no-fund && bash infra/deploy.sh)
done

# Warm-up: a freshly deployed Lambda is slow on its first call, and the first cross-service calls can time out.
# Hitting each health route once or twice wakes all three up (best effort, never stops the script).
API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='charity-http-api'].ApiId | [0]" --output text 2>/dev/null | tr -d '\r' || true)
if [ -n "${API_ID:-}" ] && [ "$API_ID" != "None" ]; then
  echo; echo "Warming up the three functions (API id $API_ID)..."
  for round in 1 2; do
    for h in campaigns pledges donations; do
      printf '  %-10s %s\n' "$h" "$(curl -s -o /dev/null -m 60 -w '%{http_code}' "http://$API_ID.execute-api.localhost.floci.io:4566/api/health/$h")"
    done
  done
fi

# Encryption at rest (KMS key + every table) and a first status view.
if [ -f ops/data-protection.sh ]; then echo; echo "Turning on encryption at rest for the tables..."; bash ops/data-protection.sh encrypt || true; fi

echo
echo "All three services are deployed."
echo "Organizer invite code (needed to register an organizer): $INVITE"
echo "Put the API id from the 'API address' line above into frontend/js/config.js"
