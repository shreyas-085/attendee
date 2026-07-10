#!/usr/bin/env bash
# Create/refresh the `app-secrets` K8s Secret in the attendee namespace directly
# from Secret Manager. Needed because the GKE Secret Manager add-on on this cluster
# mounts secrets as files but does NOT sync CSI `secretObjects` into a K8s Secret.
# Attendee's deployments read these via envFrom, and bot pods via BOT_POD_SECRETS_NAME.
# Idempotent (create-or-update). Run once during bring-up, and again after rotating
# any of the three source secrets in Secret Manager.
set -euo pipefail
PROJECT=${PROJECT:-lynkk-502014}
NS=${NS:-attendee}

D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
declare -A MAP=(
  [DJANGO_SECRET_KEY]=ATTENDEE_DJANGO_SECRET_KEY
  [CREDENTIALS_ENCRYPTION_KEY]=ATTENDEE_CREDENTIALS_ENCRYPTION_KEY
  [DATABASE_URL]=ATTENDEE_DATABASE_URL
)
for key in "${!MAP[@]}"; do
  gcloud secrets versions access latest --secret="${MAP[$key]}" --project="$PROJECT" \
    | tr -d '\n' > "$D/$key"
done
kubectl -n "$NS" create secret generic app-secrets \
  --from-file=DJANGO_SECRET_KEY="$D/DJANGO_SECRET_KEY" \
  --from-file=CREDENTIALS_ENCRYPTION_KEY="$D/CREDENTIALS_ENCRYPTION_KEY" \
  --from-file=DATABASE_URL="$D/DATABASE_URL" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "app-secrets synced from Secret Manager (project=$PROJECT ns=$NS)"
