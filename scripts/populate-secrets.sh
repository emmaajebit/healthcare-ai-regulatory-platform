#!/usr/bin/env bash
# populate-secrets.sh — write REAL values into the Secrets Manager containers
# that Terraform created with placeholders (Phase 6).
#
#   • ArgoCD admin  : random 32-char password + its bcrypt hash (password_bcrypt)
#                     — the hash is computed ONCE here, so Helm values stay
#                       stable and every Ansible run is idempotent.
#   • Grafana admin : its own random password (never reuses ArgoCD's)
#   • App secrets   : random JWT signing key; Bedrock/OpenAI keys prompted
#                     silently (press Enter to keep the current value)
#   • Helm repo     : optional, prompted silently
#
# Nothing is echoed, passed on the command line, or left in shell history:
# values go to Secrets Manager via a 0600 temp file that is shredded on exit.
#
# Usage:  bash scripts/populate-secrets.sh            # only fills placeholders
#         FORCE=1 bash scripts/populate-secrets.sh    # rotate ArgoCD/Grafana/JWT too
#
# Requires: aws CLI, jq, openssl, python3 with the `bcrypt` package
#           (pip install bcrypt) — or htpasswd from apache2-utils.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ARGOCD_ID="${ARGOCD_SECRET_ID:-/healthcare-ai/argocd/admin}"
GRAFANA_ID="${GRAFANA_SECRET_ID:-/healthcare-ai/grafana/admin}"
APP_ID="${APP_SECRET_ID:-/healthcare-ai/app/secrets}"
HELM_ID="${HELM_SECRET_ID:-/healthcare-ai/helm/repo-token}"
FORCE="${FORCE:-0}"

for c in aws jq openssl; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c is required" >&2; exit 1; }
done

umask 077
TMP="$(mktemp)"
cleanup() { [[ -f "$TMP" ]] && { shred -u "$TMP" 2>/dev/null || rm -f "$TMP"; }; }
trap cleanup EXIT

rand() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${1:-32}"; }

bcrypt_hash() {
  # ArgoCD accepts $2a$/$2b$/$2y$ bcrypt hashes.
  if python3 -c 'import bcrypt' 2>/dev/null; then
    PW="$1" python3 -c 'import bcrypt,os; print(bcrypt.hashpw(os.environ["PW"].encode(), bcrypt.gensalt(10)).decode())'
  elif command -v htpasswd >/dev/null 2>&1; then
    htpasswd -nbBC 10 "" "$1" | tr -d ':\n' | sed 's/^\$2y/\$2a/'
  else
    echo "ERROR: need python3 'bcrypt' (pip install bcrypt) or htpasswd" >&2; exit 1
  fi
}

current() { aws secretsmanager get-secret-value --region "$REGION" --secret-id "$1" --query SecretString --output text 2>/dev/null || echo '{}'; }

is_placeholder() { [[ -z "$1" || "$1" == "null" || "$1" == REPLACE_VIA* ]]; }

put() { # put <secret-id> (reads JSON from $TMP)
  aws secretsmanager put-secret-value --region "$REGION" --secret-id "$1" \
    --secret-string "file://$TMP" >/dev/null
  : > "$TMP"
  echo "   ✓ updated $1"
}

prompt_secret() { # prompt_secret <label> → prints value (empty = keep)
  local v
  read -r -s -p "   $1 (Enter to keep current): " v </dev/tty; echo >&2
  printf '%s' "$v"
}

echo ">> Region: $REGION"

# ── ArgoCD ────────────────────────────────────────────────────────────────────
CUR="$(current "$ARGOCD_ID")"
if [[ "$FORCE" == "1" ]] || is_placeholder "$(jq -r '.password_bcrypt // empty' <<<"$CUR")" \
   || is_placeholder "$(jq -r '.password // empty' <<<"$CUR")"; then
  echo ">> ArgoCD admin"
  PW="$(rand 32)"
  HASH="$(bcrypt_hash "$PW")"
  jq -n --arg p "$PW" --arg h "$HASH" '{username:"admin",password:$p,password_bcrypt:$h}' > "$TMP"
  unset PW HASH
  put "$ARGOCD_ID"
else
  echo ">> ArgoCD admin already set (FORCE=1 to rotate)"
fi

# ── Grafana ───────────────────────────────────────────────────────────────────
CUR="$(current "$GRAFANA_ID")"
if [[ "$FORCE" == "1" ]] || is_placeholder "$(jq -r '.password // empty' <<<"$CUR")"; then
  echo ">> Grafana admin"
  jq -n --arg p "$(rand 32)" '{username:"admin",password:$p}' > "$TMP"
  put "$GRAFANA_ID"
else
  echo ">> Grafana admin already set (FORCE=1 to rotate)"
fi

# ── Application secrets ──────────────────────────────────────────────────────
echo ">> Application secrets"
CUR="$(current "$APP_ID")"
JWT="$(jq -r '.jwt_signing_key // empty' <<<"$CUR")"
if [[ "$FORCE" == "1" ]] || is_placeholder "$JWT"; then JWT="$(rand 64)"; fi
BEDROCK="$(prompt_secret 'Bedrock API key')"
[[ -z "$BEDROCK" ]] && BEDROCK="$(jq -r '.bedrock_api_key // "REPLACE_VIA_AWS_CONSOLE_OR_CLI"' <<<"$CUR")"
OPENAI="$(prompt_secret 'OpenAI API key')"
[[ -z "$OPENAI" ]] && OPENAI="$(jq -r '.openai_api_key // "REPLACE_VIA_AWS_CONSOLE_OR_CLI"' <<<"$CUR")"
jq -n --arg j "$JWT" --arg b "$BEDROCK" --arg o "$OPENAI" \
  '{jwt_signing_key:$j,bedrock_api_key:$b,openai_api_key:$o}' > "$TMP"
unset JWT BEDROCK OPENAI
put "$APP_ID"

# ── Helm repo token (optional) ───────────────────────────────────────────────
read -r -p ">> Using a private Helm repo? [y/N] " USE_HELM </dev/tty
if [[ "${USE_HELM,,}" == "y" ]]; then
  read -r -p "   Helm repo username: " HU </dev/tty
  HT="$(prompt_secret 'Helm repo token')"
  jq -n --arg u "$HU" --arg t "$HT" '{username:$u,token:$t}' > "$TMP"
  unset HU HT
  put "$HELM_ID"
fi

echo ">> Done. Retrieve the ArgoCD password when needed with:"
echo "   aws secretsmanager get-secret-value --secret-id $ARGOCD_ID --query SecretString --output text | jq -r .password"
