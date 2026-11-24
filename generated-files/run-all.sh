#!/usr/bin/env bash
# ONE COMMAND to bring the whole project up on any laptop (Windows Git Bash, Linux or WSL), everything on localhost.
#
#   bash generated-files/run-all.sh        (run from the project folder; it also works from anywhere)
#
# Needs installed: Docker Desktop (running), Node.js 20+, AWS CLI v2, curl. Takes about 5 minutes the first time.
# What it does, in order:
#   1. sets the AWS CLI profile "floci" and starts the Floci emulator (the local AWS copy) with persistent storage
#   2. asks for the two optional keys (hidden typing, nothing is saved in files or shown):
#        Resend API key        -> donation e-mails (press Enter to skip: no e-mails, everything else works)
#        Turnstile secret key  -> human check on sign-up and login (press Enter to skip: the check stays off)
#   3. deploys the three services (one shared random token secret and a new organizer invite code), encrypts the tables
#   4. puts the right API address into the website, uploads it to a Floci S3 bucket, creates the monitoring alarm
#   5. warms the functions up and prints the addresses
# Safe to run again: it reuses the secrets and the invite code already created on this laptop.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"   # the generated-files folder
cd "$HERE/.."                            # the project folder: services, frontend, ops, deploy-all.sh
export AWS_PROFILE=floci MSYS_NO_PATHCONV=1
SITE_KEY_DEFAULT="0x4AAAAAAGPcZSyupzRQ-TRe"   # Turnstile PUBLIC site key (not a secret); it is valid for the hostname "localhost"
clean() { tr -d '\r'; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1. $2"; exit 1; }; }

echo "== 0. Checking the tools =="
need docker "Install Docker Desktop and start it."
need node   "Install Node.js 20 or newer."
need aws    "Install the AWS CLI v2."
need curl   "Install curl."
docker info >/dev/null 2>&1 || { echo "Docker is installed but not running. Start Docker Desktop and run this again."; exit 1; }

echo "== 1. AWS profile and Floci =="
aws configure set aws_access_key_id test --profile floci
aws configure set aws_secret_access_key test --profile floci
aws configure set region us-east-1 --profile floci
aws configure set endpoint_url http://localhost:4566 --profile floci
(cd "$HERE/floci" && docker compose up -d)
printf 'Waiting for Floci'
for _ in $(seq 1 60); do
  aws dynamodb list-tables >/dev/null 2>&1 && break
  printf '.'; sleep 2
done
echo
aws dynamodb list-tables >/dev/null 2>&1 || { echo "Floci did not answer on http://localhost:4566. Check: docker ps"; exit 1; }
echo "Floci is up."

store_secret() { # name value
  aws secretsmanager create-secret --name "$1" --secret-string "$2" >/dev/null 2>&1 \
    || aws secretsmanager put-secret-value --secret-id "$1" --secret-string "$2" >/dev/null
}

echo "== 2. Optional keys (hidden; press Enter to skip) =="
read -r -s -p "Resend API key (starts with re_), or Enter to skip: " RESEND; echo
RESEND=${RESEND//$'\r'/}
if [ -n "$RESEND" ]; then store_secret charity/resend-api-key "$RESEND"; echo "  Resend key stored (length ${#RESEND}). Mail goes to the e-mail address of the Resend account only."; else echo "  skipped: donation e-mails are off"; fi
unset RESEND
read -r -s -p "Turnstile SECRET key (starts with 0x4), or Enter to skip: " TSECRET; echo
TSECRET=${TSECRET//$'\r'/}
TURNSTILE=off
if [ -n "$TSECRET" ]; then store_secret charity/turnstile-secret "$TSECRET"; TURNSTILE=enforce; echo "  Turnstile secret stored (length ${#TSECRET}): the human check will be ON"; else echo "  skipped: the human check stays off"; fi
unset TSECRET

echo "== 3. Deploying the three services =="
DRY_RUN=1 bash deploy-all.sh >/dev/null            # creates infra/deploy.env in each service, with the shared secret and invite code
CAMP=campaign-service/infra/deploy.env
if grep -q '^TURNSTILE_MODE=' "$CAMP"; then sed -i "s/^TURNSTILE_MODE=.*/TURNSTILE_MODE=$TURNSTILE/" "$CAMP"; else printf 'TURNSTILE_MODE=%s\n' "$TURNSTILE" >> "$CAMP"; fi
bash deploy-all.sh

API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='charity-http-api'].ApiId | [0]" --output text | clean)
[ -n "$API_ID" ] && [ "$API_ID" != "None" ] || { echo "Could not find the API id."; exit 1; }
API="http://$API_ID.execute-api.localhost.floci.io:4566"
INVITE=$(grep '^INVITE_CODE=' "$CAMP" | cut -d= -f2- | clean)

echo "== 4. Website and monitoring =="
SITE_KEY=""; [ "$TURNSTILE" = enforce ] && SITE_KEY="$SITE_KEY_DEFAULT"
sed -i "s|API_BASE_URL: '[^']*'|API_BASE_URL: '$API'|; s|TURNSTILE_SITE_KEY: '[^']*'|TURNSTILE_SITE_KEY: '$SITE_KEY'|" frontend/js/config.js
aws s3 mb s3://charity-frontend >/dev/null 2>&1 || true
aws s3 sync frontend s3://charity-frontend --exclude "node_modules/*" --exclude ".git/*" >/dev/null
echo "website uploaded to the Floci S3 bucket charity-frontend"
bash ops/monitor.sh setup || echo "(monitoring setup failed: run 'bash ops/monitor.sh setup' later)"

echo "== 5. Warm-up =="
bash ops/warmup.sh "$API_ID"

echo
echo "=============================================================="
echo " Everything is running on this laptop."
echo "   Website (Floci S3):  http://localhost:4566/charity-frontend/index.html"
echo "   Website (alternative): cd frontend && npm install && npm start   then http://localhost:8080"
echo "   API:                 $API"
echo "   Organizer invite code (type it in the sign-up form): $INVITE"
echo "   Human check (Turnstile): $TURNSTILE"
echo " Use the address with 'localhost', not 127.0.0.1."
echo " Before a demo:  bash ops/warmup.sh $API_ID     and   bash ops/monitor.sh setup"
echo " Tests:          bash ops/security-tests.sh $API_ID      (needs the human check off: TURNSTILE_MODE=off in campaign deploy.env, redeploy)"
echo "                 bash ops/security-tests.sh $API_ID human  (needs it on)"
echo "=============================================================="
