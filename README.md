# Charity Donation Drive · Team 37

Cloud Computing and Cloud Security, final phase. Campaigns list the items they need and a target for each
(clothes, food, books). Donors pledge items, organizers confirm what actually arrived, and everyone sees
progress toward each target. It runs on **Floci**, a free local copy of AWS (Lab 7): no real AWS account is used.


## 0. Run everything on another laptop

Install **Docker Desktop** (running), **Node.js 20+**, **AWS CLI v2** and **Git Bash** (Windows) or use Linux/WSL. Unzip this folder, open Git Bash inside it and run:

```bash
bash generated-files/run-all.sh
```

It starts Floci, deploys the three services, encrypts the tables, uploads the website, creates the alarm and prints the addresses. About 5 minutes the first time.
It asks for two **optional** keys with hidden typing (nothing is written to a file): the Resend API key (donation e-mails) and the Cloudflare Turnstile secret key (human check).
Press Enter on both to run with no e-mails and no human check. Everything else works the same.

What does **not** travel in the zip (on purpose): the token-signing secret and invite code (a new random pair is made on each laptop), the Resend and Turnstile secret keys,
and the data in the tables (a new laptop starts empty: register the demo users again). Open the website at `http://localhost:4566/charity-frontend/index.html`
(the word `localhost`, not `127.0.0.1`). The Turnstile site key in `generated-files/run-all.sh` is public and is valid for the hostname `localhost`.
Resend's test sender only delivers to the e-mail address of the Resend account that owns the key.

## 1. What is in this folder

| Folder | What it is | Becomes repo |
|---|---|---|
| `campaign-service/` | accounts, login, campaigns (Lambda + DynamoDB tables `CharityCampaigns`, `CharityUsers`) | repo 1 |
| `pledge-service/` | pledges (Lambda + table `CharityPledges`) | repo 2 |
| `donation-progress-service/` | confirmed donations and progress (Lambda + table `CharityDonations`) | repo 3 |
| `frontend/` | the website: static HTML/CSS/JS, no build step | repo 4 |
| `generated-files/floci/` | `docker-compose.yml` that starts Floci | not a repo |
| `dev-tools/` | local gateway and cross-service tests that need no Docker (not used in the demo) | not a repo |
| `generated-files/evidence/` | saved results of the live security tests; put your screenshots here | goes with the report |
| `generated-files/run-all.sh` | one command for a new laptop: Floci, keys, deploy, website, alarm, warm-up | not a repo |
| `deploy-all.sh` | deploys the three services in the right order with one shared secret, then warms them up | not a repo |
| `ops/monitor.sh` | metric filters + alarm on security events (`setup`), and a status view (log query, metric, alarm) | goes with the report |
| `ops/security-tests.sh` | 24 live security tests with PASS/FAIL (report section 12); `bash ops/security-tests.sh <API-ID>` | goes with the report |
| `ops/data-protection.sh` | KMS encryption at rest on the four tables, on-demand backups and restore (`encrypt`, `status`, `backup`, `restore <Table>`); `deploy-all.sh` runs `encrypt` for you | goes with the report |
| `ops/warmup.sh` | wakes the three functions before a demo; `bash ops/warmup.sh <API-ID>` | goes with the report |

The TA asked for the backend to be split into one repo per service and the frontend alone in its own repo. Each of the four
folders above is already laid out to be its own repo (own `package.json`, `.gitignore`, `README.md`, `docs/`).

```
Browser (frontend, http://localhost:8080)
   │  one address: API Gateway (only listed routes get through)
   ├─▶ campaign-service ───────▶ DynamoDB (CharityCampaigns, CharityUsers)
   ├─▶ pledge-service ─────────▶ DynamoDB (CharityPledges)
   └─▶ donation-progress-service ▶ DynamoDB (CharityDonations)

Services call each other with Lambda invoke and short-lived (60 s) service tokens:
   Pledge ──▶ Campaign   is the campaign open? what items?
   Pledge ──▶ Donation   how much is still needed?
   Donation ─▶ Pledge    open pledges; record a delivery
   Donation ─▶ Campaign  who owns it? mark it completed
   Campaign ─▶ Donation  percent complete / urgency ranking
```

Each service has its own IAM role (`infra/iam/policy.json`) listing only its own tables and the functions it may call.
Logs are one JSON line per request and per security event in CloudWatch Logs.

## 2. What each service does beyond CRUD (the TA's main complaint)

| Service | Business rules and logic |
|---|---|
| Campaign | organizer-only invite code; password hashing; signed login tokens; auto-close at the deadline; progress percent and urgency ranking (asks Donation); only the owner can close |
| Pledge | a pledge cannot exceed what is still needed (409 `EXCEEDS_REMAINING_NEED`); max 20 open pledges per donor; pledges expire after 7 days; atomic partial receipts that cannot over-receive; only the owner can cancel |
| Donation and Progress | only the campaign's organizer can confirm; quantity cannot exceed what the pledge still expects; partial receipts; progress = target, received, pledged, remaining; marks the campaign `completed` when every target is met |

## 3. What has been checked, and what has not

Checked on Moamen's PC on Floci on 2026-11-21:

- Tests: Campaign 23 of 23, Donation and Progress 31 of 31, Pledge 20 of 20 pass.
- All three services deployed to Floci and talk to each other (Lambda to Lambda).
- Full flow with curl: pledge 15 of 20, a second pledge of 10 refused (409), a donor trying to confirm refused (403),
  organizer confirms 10 (pledge `partial`), progress shows received 10, pledged 5, remaining 5 (50%).
- Organizer registration without the invite code is refused (403).
- Floci really runs: Secrets Manager (store and read), KMS (encrypt and decrypt), CloudWatch alarm (reached `ALARM`).
- The website loads the campaign list from the real API, and is also hosted in a Floci S3 bucket (`http://localhost:4566/charity-frontend/index.html`).
- Data survives a Floci restart (persistent storage mode, see `generated-files/floci/docker-compose.yml`).
- External service: Resend e-mail to the donor when a delivery is confirmed, key in Secrets Manager (see `donation-progress-service/README.md`). Unit-tested with a fake HTTP call, and a live send was received in the Resend account owner's inbox.
- Security tests: `ops/security-tests.sh` gives 24 of 24 on Floci (no token, forged token, wrong role, ownership, internal routes, invalid input, business rules, headers, CORS, no secrets in logs, brute force 429).
- Encryption at rest and recovery: all four tables use the customer-managed KMS key `alias/charity-data`; a backup of every table was taken and `CharityDonations` was restored into a second table with the same item count (`ops/data-protection.sh`).
- Monitoring: the metric filter on `security_event` log lines fills the metric `Charity/SecurityEvents` (verified: six failed logins gave a datapoint of 6). Floci needs a minute or two to evaluate the filter, so wait before reading the metric.

**Not checked yet**, please do and report:

- Website: login, pledge, confirm receipt from the browser (the API behind them works with curl).
- `npm test` in `pledge-service` (the other two pass; a table-name bug in `tests/dynamo.test.js` is fixed in this folder).
- API Gateway throttling: tested on Floci, the setting is accepted but **not enforced** (15 quick requests against a 2/s limit all returned 200). The in-code per-IP rate limit is the demonstrated control. WAF cannot be attached to an HTTP API, so it is a design option in the report only.
- The alarm `charity-security-events` reacting to the filter-fed metric: run `bash ops/monitor.sh setup`, make 6 failed logins within one minute, wait 2 to 3 minutes, run `bash ops/monitor.sh` and screenshot it.

## 4. Run it on your PC

You need: Docker Desktop (running), Node.js 20 or newer, AWS CLI v2, Git Bash (Windows). Run every command in **Git Bash**.

**Step 0. AWS profile for Floci** (skip if you did Lab 7 and `aws s3 ls --profile floci` already works):
```bash
aws configure set aws_access_key_id test --profile floci
aws configure set aws_secret_access_key test --profile floci
aws configure set region us-east-1 --profile floci
aws configure set endpoint_url http://localhost:4566 --profile floci
```

**Step 1. Start Floci:**
```bash
cd generated-files/floci
docker compose up -d
docker ps                      # a floci container with 4566 in PORTS
cd ../..
export AWS_PROFILE=floci MSYS_NO_PATHCONV=1
aws dynamodb list-tables       # {"TableNames": []} means Floci answers
```

**Step 2. Deploy the three services** (about 3 minutes the first time):
```bash
bash deploy-all.sh
```
It creates `infra/deploy.env` in each service with the **same** random `TOKEN_SECRET`, installs each service's packages, builds the Lambda zip,
creates tables, roles, functions and routes, and ends by printing the API address and your **organizer invite code**. Copy both.
The API address looks like `http://918bb3b597.execute-api.localhost.floci.io:4566`; the part before `.execute-api` is the API id.

**Step 3. Start the website:**

Edit `frontend/js/config.js` and replace `YOUR-API-ID` with your id. Then:
```bash
cd frontend
npm install
npm start
```
Open **http://localhost:8080** (type `localhost`, not `127.0.0.1`; only `localhost` is allowed by the services' CORS list).

**Step 4. Try it:** register an organizer (use the invite code from step 2) and a donor, create a campaign as the organizer,
pledge as the donor, then confirm receipt as the organizer and watch the progress move.

Quick check without the website:
```bash
curl http://<API-ID>.execute-api.localhost.floci.io:4566/api/health/campaigns
curl http://<API-ID>.execute-api.localhost.floci.io:4566/api/health/donations
curl http://<API-ID>.execute-api.localhost.floci.io:4566/api/health/pledges
```

**Tests** (in each service folder, no Floci needed): `npm install` then `npm test`.

### Cloudflare Turnstile (human check on sign-up and login)

Turnstile stops scripted brute force and bot sign-ups. The website shows the widget and sends the token it earns as `turnstileToken`;
the Campaign service confirms it with Cloudflare using a secret key kept in Secrets Manager. It is **off by default** and fails closed when on
(no token or Cloudflare unreachable: no login).

1. Cloudflare dashboard > Turnstile > add a widget for hostname `localhost`; you get a public **site key** and a private **secret key**.
2. Store the secret key (it is not echoed): `read -r -s -p "Turnstile secret: " S; echo; aws secretsmanager create-secret --name charity/turnstile-secret --secret-string "$S" >/dev/null; unset S`
3. Put the site key in `frontend/js/config.js` (`TURNSTILE_SITE_KEY`) and upload the website again.
4. Add `TURNSTILE_MODE=enforce` to `campaign-service/infra/deploy.env`, then `cd campaign-service && bash infra/deploy.sh`.
5. Check: `bash ops/security-tests.sh <API-ID> human` (4 tests). The 24 main tests send no token, so run them with `TURNSTILE_MODE=off`.

## 5. Problems we already hit (and the fix)

| What you see | Why | Fix |
|---|---|---|
| `docker compose up-d` unknown command | missing space | `docker compose up -d` |
| `no configuration file provided` | you are not in the `generated-files/floci` folder | `cd generated-files/floci` first |
| `bash: cd: ../x: No such file` | wrong starting folder | run `pwd` and `ls` to see where you are |
| Website says **Cannot reach the server**, Console shows `localhost:3000 ... ERR_CONNECTION_REFUSED` | `config.js` still has the wrong address, or the browser cached the old file | set `API_BASE_URL`, then `Ctrl+Shift+R`; `npm start` already disables the server cache |
| Console shows **violates the Content Security Policy** | `connect-src` in `frontend/index.html` does not list your API host | the emulator host pattern is already allowed; if you changed hosts add the exact one |
| Page opened at `127.0.0.1:8080` and calls fail | only `http://localhost:8080` is in CORS_ORIGINS | use `localhost` |
| `401 UNAUTHENTICATED` on pages that should be public | the three services have different `TOKEN_SECRET` values | use `deploy-all.sh`; it prints one fingerprint per service and stops if they differ |
| `403 Invite code is not valid` | wrong organizer invite code | it is printed at the end of `deploy-all.sh` and stored in `campaign-service/infra/deploy.env` |
| `base64: invalid input` after an AWS CLI command | Windows line endings (`\r`) in the output | harmless; add `\| tr -d '\r'` before `base64 -d` |
| `npm test` fails with `TableName must be at least 3 characters` | old test used a table named `T` | already fixed here (`TestTable`) |
| Everything returns 404 or tables are gone after a PC restart | the Floci container restarted and lost its data | run `bash deploy-all.sh` again; register the demo users again |
| You cannot type in Git Bash | that window runs `npm start` | open a second Git Bash window |

## 6. Rules for the team

- **Never commit** `infra/deploy.env`, any `.env`, `node_modules/` or `lambda.zip`. Each repo's `.gitignore` already excludes them. Check `git status` before every commit.
- Anything pasted into chat or screenshots must not contain secrets, tokens or the invite code.
- Do not share the old Neon zip: its database password was rotated, but treat it as burned.
- If you change a route or a response shape, change `docs/API_CONTRACT.md` and tell the others first.

## 7. What is left (final phase requirements)

| Item | Notes |
|---|---|
| Security services on Floci | Secrets Manager (key stored, token secret still to move), KMS and CloudWatch alarm work; throttling is not enforced (see above) |
| Metric and alert | `bash ops/monitor.sh setup` creates the filters and alarm; trigger it on purpose and screenshot `bash ops/monitor.sh` |
| 8 or more security tests | many already exist in each `tests/api.test.js` and `lib.test.js`; list them in the report |
| Threat model, 6 or more threats mapped to controls | brute force login, token forgery, over-pledging, role abuse, injection, secret leakage, flooding |
| Least privilege, encryption, shared responsibility | IAM policies exist; add KMS/secrets evidence and the 3 provider + 3 team items |
| Recovery, cost statement, limitations | short sections |
| Four public repos, no secrets | one per folder in section 1 |
| Demo video (5 minutes at most), live demo | use the flow in section 4, step 4 |

Decisions the team still has to confirm: Floci with DynamoDB as the platform (instead of Neon), who owns login
(`POST /api/users` and `POST /api/tokens` are in the Campaign service), and `docs/API_CONTRACT.md` as the shared contract.

## 8. How this answers the TA's phase 1 feedback

| TA comment | What we did |
|---|---|
| Services were only CRUD | real rules and cross-service calls (section 2) |
| Everything in one repo | four repos: three services and the frontend |
| No cloud service protects against a threat | per-service IAM roles, API Gateway publishes only listed routes (internal routes are unreachable), signed tokens, invite code, rate limits, security headers and CSP; Secrets Manager, KMS and a CloudWatch alarm confirmed working on Floci |
| Update the architecture, add security and traffic services | diagram in section 1; the report must also show the gateway, roles, tables, logs and service-to-service calls |

## 9. Known limitations (for the report)

- Rate limiting is per running Lambda container, so it slows one attacker but is not a global limit.
- No transaction across services: if a step fails half-way the error is logged and the data is not rolled back.
- Deadline closing and pledge expiry happen when data is read, not on a timer.
- Lists use a DynamoDB `Scan` with filters (fine for a course project; an index would be used at scale).
- The token-signing secret and invite code are Lambda environment variables (the Resend and Turnstile keys are in Secrets Manager).
- Turnstile needs the internet and a Cloudflare account; with `TURNSTILE_MODE=enforce` and no connection nobody can sign in (fail closed).
- Floci stores IAM policies but does not enforce them by default, so least privilege is shown by the policy files.
- Floci removes idle Lambda containers after 5 minutes by default, and the first request afterwards can fail with 500 ("Failed to get next invocation"). `generated-files/floci/docker-compose.yml` raises the idle time to 30 min and caps idle containers at 4 per function and the cold-start allowance to 60 s, the functions have a 30 s timeout, and `ops/warmup.sh` wakes them before a demo.
- Metric filters on Floci take a minute or two to produce datapoints, so alarms are not instant in the demo (rehearse it beforehand).
- API Gateway throttling and WAF are not available as working controls on Floci; the in-code rate limit is what is demonstrated.
