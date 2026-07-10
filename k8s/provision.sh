#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Attendee on GKE — one-time GCP provisioning (project lynkk-502014 / asia-south1).
#
# ⚠️  BILLABLE. REVIEW and run SECTION BY SECTION, not blindly. Most commands are
#     create-once; re-running errors harmlessly ("already exists").
#     Requires: gcloud authenticated as admin@lynkk.ai.
#
# COST-MINIMAL design for LOW traffic (differs from the old capturemeet runbook):
#   • Dedicated ZONAL cluster (1 zonal/Autopilot cluster is free per billing acct).
#   • Control pool e2-standard-2 ×1 (web/worker/scheduler/redis all fit).
#   • Bot pool e2-standard-4, autoscaling min=0 max=2 → scales to ZERO when idle,
#     so no bot-node cost between meetings. e2 (not n2) dodges the N2 quota=0 wall
#     on fresh projects and is cheaper for low volume; re-pin to n2 under load.
#   • Cloud SQL db-g1-small (shared core, 1.7 GB), 10 GB, PRIVATE IP, sslmode=require
#     (Attendee's production-gke.py hardcodes ssl_require=True → no cloud-sql-proxy).
#   • Native GCS via Workload Identity (no keys — org policy may block SA/HMAC keys).
#     Signed download URLs use the IAM SignBlob API, so the SA gets
#     serviceAccountTokenCreator on itself.
#   • Redis in-cluster (mirror.gcr.io image, no Docker Hub rate limit / repo setup).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

PROJECT=lynkk-502014
REGION=asia-south1
ZONE=asia-south1-a
CLUSTER=attendee-cluster
GSA=attendee-app@lynkk-502014.iam.gserviceaccount.com
BUCKET=lynkk-attendee-recordings
SQL_INSTANCE=attendee-pg
SQL_DB=attendee
SQL_USER=attendee
SQL_TIER=db-g1-small
NETWORK=default
DOMAIN=attendee.capturemeet.dev

gcloud config set project "$PROJECT"

# ── 0. APIs ───────────────────────────────────────────────────────────────────
gcloud services enable \
  compute.googleapis.com container.googleapis.com \
  servicenetworking.googleapis.com sqladmin.googleapis.com \
  artifactregistry.googleapis.com secretmanager.googleapis.com \
  storage.googleapis.com cloudbuild.googleapis.com

# ── 1. Artifact Registry repo for the Attendee image ──────────────────────────
gcloud artifacts repositories create attendee \
  --repository-format=docker --location="$REGION" \
  --description="Attendee bot service images" || true

# ── 2. GCS bucket + lifecycle (purge recordings after 3 days) ─────────────────
gcloud storage buckets create "gs://$BUCKET" --location="$REGION" \
  --uniform-bucket-level-access || true
printf '{"rule":[{"action":{"type":"Delete"},"condition":{"age":3}}]}' > /tmp/attendee-lifecycle.json
gcloud storage buckets update "gs://$BUCKET" --lifecycle-file=/tmp/attendee-lifecycle.json

# ── 3. Service account + IAM ──────────────────────────────────────────────────
gcloud iam service-accounts create attendee-app \
  --display-name="Attendee bot service" || true
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:$GSA" --role="roles/secretmanager.secretAccessor"
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" \
  --member="serviceAccount:$GSA" --role="roles/storage.objectAdmin"
# Workload Identity: k8s SA attendee/attendee-app ⇒ GCP SA attendee-app.
gcloud iam service-accounts add-iam-policy-binding "$GSA" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT}.svc.id.goog[attendee/attendee-app]"
# Self serviceAccountTokenCreator → mint V4 signed GCS URLs via IAM SignBlob (keyless).
gcloud iam service-accounts add-iam-policy-binding "$GSA" \
  --role="roles/iam.serviceAccountTokenCreator" --member="serviceAccount:$GSA"
# Let GKE nodes (default compute SA) pull images from Artifact Registry.
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/artifactregistry.reader"

# ── 4. Cloud SQL Postgres on a PRIVATE IP ─────────────────────────────────────
# Allocate a range + peer servicenetworking on the default VPC.
gcloud compute addresses create google-managed-services-"$NETWORK" \
  --global --purpose=VPC_PEERING --prefix-length=16 --network="$NETWORK" || true
gcloud services vpc-peerings connect \
  --service=servicenetworking.googleapis.com \
  --ranges=google-managed-services-"$NETWORK" --network="$NETWORK" || true
gcloud sql instances create "$SQL_INSTANCE" \
  --database-version=POSTGRES_15 --tier="$SQL_TIER" --region="$REGION" \
  --network="projects/$PROJECT/global/networks/$NETWORK" --no-assign-ip \
  --storage-size=10
gcloud sql databases create "$SQL_DB" --instance="$SQL_INSTANCE"
SQL_PASS=$(python3 -c "import secrets;print(secrets.token_urlsafe(32))")
gcloud sql users create "$SQL_USER" --instance="$SQL_INSTANCE" --password="$SQL_PASS"
SQL_IP=$(gcloud sql instances describe "$SQL_INSTANCE" \
  --format='value(ipAddresses[0].ipAddress)')   # the PRIVATE_NETWORK address
echo "Postgres private IP: $SQL_IP"

# ── 5. Secrets → Secret Manager (names match 03-secretproviderclass.yaml) ──────
DJANGO_KEY=$(python3 -c "import secrets;print(secrets.token_urlsafe(64))")
FERNET_KEY=$(python3 -c "from cryptography.fernet import Fernet;print(Fernet.generate_key().decode())")
printf '%s' "$DJANGO_KEY" | gcloud secrets create ATTENDEE_DJANGO_SECRET_KEY --data-file=- || \
  printf '%s' "$DJANGO_KEY" | gcloud secrets versions add ATTENDEE_DJANGO_SECRET_KEY --data-file=-
printf '%s' "$FERNET_KEY" | gcloud secrets create ATTENDEE_CREDENTIALS_ENCRYPTION_KEY --data-file=- || \
  printf '%s' "$FERNET_KEY" | gcloud secrets versions add ATTENDEE_CREDENTIALS_ENCRYPTION_KEY --data-file=-
printf 'postgresql://%s:%s@%s:5432/%s' "$SQL_USER" "$SQL_PASS" "$SQL_IP" "$SQL_DB" \
  | gcloud secrets create ATTENDEE_DATABASE_URL --data-file=- || \
  printf 'postgresql://%s:%s@%s:5432/%s' "$SQL_USER" "$SQL_PASS" "$SQL_IP" "$SQL_DB" \
  | gcloud secrets versions add ATTENDEE_DATABASE_URL --data-file=-

# ── 6. GKE cluster (dedicated, zonal, minimal) ────────────────────────────────
# Workload Identity + the GKE Secret Manager add-on (provides the
# secrets-store-gke.csi.k8s.io driver + SecretProviderClass provider: gke).
gcloud container clusters create "$CLUSTER" \
  --zone="$ZONE" \
  --release-channel=regular \
  --workload-pool="${PROJECT}.svc.id.goog" \
  --enable-secret-manager \
  --machine-type=e2-standard-2 --num-nodes=1 --disk-size=50 \
  --node-labels=pool=attendee-control \
  --workload-metadata=GKE_METADATA \
  --no-enable-basic-auth
# Bot pool — autoscaled to ZERO, tainted, bigger boot disk for recordings.
gcloud container node-pools create attendee-bots \
  --cluster="$CLUSTER" --zone="$ZONE" \
  --machine-type=e2-standard-4 --disk-size=100 \
  --enable-autoscaling --min-nodes=0 --max-nodes=2 --num-nodes=0 \
  --node-labels=workload=bot \
  --node-taints=workload=bot:NoSchedule \
  --workload-metadata=GKE_METADATA

# ── 7. Global static IP for the ingress ───────────────────────────────────────
gcloud compute addresses create attendee-ip --global || true
gcloud compute addresses describe attendee-ip --global --format='value(address)'
echo ">> Point DNS A record $DOMAIN → the IP above (for the managed cert)."

echo "DONE. Next: kubectl apply -f k8s/bootstrap/ ; kubectl apply -f k8s/"
