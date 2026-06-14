#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Attendee on GKE — one-time GCP provisioning (project capturemeet / asia-south1).
#
# ⚠️  BILLABLE + touches the production `meet-cluster`. REVIEW and run SECTION BY
#     SECTION, not blindly. Most commands are create-once; re-running errors
#     harmlessly ("already exists"). Requires: gcloud as admin@capturemeet.dev.
#
# Design choices baked in here:
#   • Cloud SQL Postgres on a PRIVATE IP, app connects directly with sslmode=require
#     (Attendee's production-gke.py hardcodes ssl_require=True → no cloud-sql-proxy).
#   • Native GCS via Workload Identity (no keys — org policy blocks SA/HMAC keys).
#     Attendee patched to add a django-storages GCS backend; signed download URLs
#     use the IAM SignBlob API, so the SA gets serviceAccountTokenCreator on itself.
#   • Reuse meet-cluster; add a fixed control pool + an autoscaled, tainted bot pool.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

PROJECT=capturemeet
REGION=asia-south1
ZONE=asia-south1-a
CLUSTER=meet-cluster
GSA=attendee-app@capturemeet.iam.gserviceaccount.com
BUCKET=capturemeet-attendee-recordings
SQL_INSTANCE=attendee-pg
SQL_DB=attendee
SQL_USER=attendee

gcloud config set project "$PROJECT"

# ── 0. APIs (servicenetworking is the new one, for private-IP Cloud SQL) ───────
gcloud services enable \
  servicenetworking.googleapis.com sqladmin.googleapis.com \
  artifactregistry.googleapis.com secretmanager.googleapis.com \
  compute.googleapis.com container.googleapis.com storage.googleapis.com

# ── 1. Artifact Registry repo for the Attendee image ──────────────────────────
gcloud artifacts repositories create attendee \
  --repository-format=docker --location="$REGION" \
  --description="Attendee bot service images" || true

# ── 2. GCS bucket + lifecycle + HMAC keys (S3-interop) ────────────────────────
gcloud storage buckets create "gs://$BUCKET" --location="$REGION" \
  --uniform-bucket-level-access || true
# Purge recordings after 3 days (matches RECORDING_RETENTION_DAYS).
printf '{"rule":[{"action":{"type":"Delete"},"condition":{"age":3}}]}' > /tmp/attendee-lifecycle.json
gcloud storage buckets update "gs://$BUCKET" --lifecycle-file=/tmp/attendee-lifecycle.json

# ── 3. Service account + IAM ──────────────────────────────────────────────────
gcloud iam service-accounts create attendee-app \
  --display-name="Attendee bot service" || true
# CSI Secret Manager sync (Workload Identity) + GCS access (used by the HMAC key's SA).
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:$GSA" --role="roles/secretmanager.secretAccessor"
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" \
  --member="serviceAccount:$GSA" --role="roles/storage.objectAdmin"
# Workload Identity: let the k8s SA attendee/attendee-app impersonate the GCP SA.
gcloud iam service-accounts add-iam-policy-binding "$GSA" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT}.svc.id.goog[attendee/attendee-app]"
# Self serviceAccountTokenCreator → lets the SA mint V4 signed GCS URLs via IAM
# SignBlob without a private key (keyless, org-policy-compliant).
gcloud iam service-accounts add-iam-policy-binding "$GSA" \
  --role="roles/iam.serviceAccountTokenCreator" --member="serviceAccount:$GSA"

# ── 4. Cloud SQL Postgres on a PRIVATE IP ─────────────────────────────────────
NETWORK=$(gcloud container clusters describe "$CLUSTER" --zone "$ZONE" \
  --format='value(network)')
echo "Cluster network: $NETWORK"
# Allocate a range + peer servicenetworking (skip if already present on this VPC).
gcloud compute addresses create google-managed-services-"$NETWORK" \
  --global --purpose=VPC_PEERING --prefix-length=16 --network="$NETWORK" || true
gcloud services vpc-peerings connect \
  --service=servicenetworking.googleapis.com \
  --ranges=google-managed-services-"$NETWORK" --network="$NETWORK" || true
# Private-IP-only Postgres 15.
gcloud sql instances create "$SQL_INSTANCE" \
  --database-version=POSTGRES_15 --tier=db-custom-1-3840 --region="$REGION" \
  --network="projects/$PROJECT/global/networks/$NETWORK" --no-assign-ip --storage-size=20
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

# ── 6. Node pools on meet-cluster ─────────────────────────────────────────────
# Control pool — fixed, holds web/worker/scheduler/redis.
gcloud container node-pools create attendee-control \
  --cluster="$CLUSTER" --zone="$ZONE" \
  --machine-type=e2-standard-4 --num-nodes=1 \
  --node-labels=pool=attendee-control \
  --workload-metadata=GKE_METADATA
# Bot pool — autoscaled, tainted, big boot disk for 10Gi ephemeral/bot.
# n2-standard-16: N2 has quota in asia-south1 (N2D_CPUS quota is 0 → would need an
# increase request; N2 is dedicated-core and fine for CPU-bound Chrome bots).
gcloud container node-pools create attendee-bots \
  --cluster="$CLUSTER" --zone="$ZONE" \
  --machine-type=n2-standard-16 --disk-size=200 \
  --enable-autoscaling --min-nodes=1 --max-nodes=3 --num-nodes=1 \
  --node-labels=workload=bot \
  --node-taints=workload=bot:NoSchedule \
  --workload-metadata=GKE_METADATA

# ── 7. Global static IP for the ingress ───────────────────────────────────────
gcloud compute addresses create attendee-ip --global || true
gcloud compute addresses describe attendee-ip --global --format='value(address)'
echo ">> Point DNS A record attendee.capturemeet.dev → the IP above (for the cert)."

echo "DONE. Next: kubectl apply -f k8s/bootstrap/ ; kubectl apply -f k8s/"
