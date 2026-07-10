# Attendee on GKE — deployment runbook

Self-hosts Attendee on a **dedicated, cost-minimal GKE cluster** in project
`lynkk-502014` / `asia-south1`. Serves the control-plane API + webhook receiver at
`https://attendee.capturemeet.dev` and launches one ephemeral bot pod per meeting for
recording + 2-way conversation. Raw manifests + `kubectl` + Workload Identity, GKE
Secret Manager add-on, and Artifact Registry.

## Architecture (minimal / low-traffic sizing)

- **Cluster**: zonal `attendee-cluster` (`asia-south1-a`). One zonal cluster is free
  per billing account. Workload Identity + the GKE Secret Manager add-on enabled.
- **Control plane** (`pool=attendee-control`, `e2-standard-2` ×1): `attendee-web`
  (gunicorn), `attendee-worker` (celery), `attendee-scheduler`, `redis` (in-cluster).
- **Bot pods** (`attendee-bots` pool, `e2-standard-4`, autoscaled **min 0 / max 2**,
  tainted): one ephemeral pod per meeting, created by the control plane via the k8s
  API (`LAUNCH_BOT_METHOD=kubernetes`), torn down at meeting end. The pool **scales to
  zero** between meetings, so there is no idle bot-node cost. Pods are targeted onto
  the pool by the `BOT_POD_SPEC_DEFAULT` nodeSelector/toleration patch in
  `02-configmap.yaml`.
- **Postgres**: Cloud SQL `attendee-pg` (`db-g1-small`, 10 GB) on a **private IP**,
  direct `sslmode=require` (no proxy — works for the dynamic bot pods too).
- **Redis**: in-cluster (`04-redis.yaml`), image from `mirror.gcr.io` (no Docker Hub
  rate limits, no pull-through repo to maintain).
- **Storage**: native GCS via Workload Identity (no keys; signed URLs via IAM
  SignBlob). `STORAGE_PROTOCOL=gcs`; final recording mp4 uploads via a `gcs` peer to
  Attendee's azure/s3 uploaders (`bots/bot_controller/gcs_file_uploader.py`).
- **Maintenance**: `10-cronjobs.yaml` reaps completed bot pods + stuck bots every 5 min.

## One-time bring-up

1. **Provision GCP infra** — review then run section-by-section (as `admin@lynkk.ai`):
   ```bash
   ./k8s/provision.sh
   ```
   Captures: Artifact Registry repo, GCS bucket, `attendee-app` SA + IAM + Workload
   Identity (+ self serviceAccountTokenCreator for signed URLs), the default-compute
   SA's `cloudbuild.builds.builder` (Cloud Build + node image pull), VPC peering +
   private-IP Cloud SQL, Secret Manager secrets, the dedicated cluster + two node
   pools, and the global static IP.
   **Manual sub-step it prints:** point the `attendee.capturemeet.dev` DNS A record at
   the static IP (needed before the managed cert provisions).

2. **Cluster-scoped bootstrap** (once):
   ```bash
   gcloud container clusters get-credentials attendee-cluster --zone asia-south1-a
   kubectl apply -f k8s/bootstrap/      # namespace
   ```

3. **Build & push the image** (Cloud Build; uses the Dockerfile's public ubuntu base):
   ```bash
   SHA=$(git rev-parse --short HEAD)
   IMG=asia-south1-docker.pkg.dev/lynkk-502014/attendee/attendee
   gcloud builds submit --tag "$IMG:$SHA" --timeout=3600 .
   ```

4. **Create the `app-secrets` K8s Secret** from Secret Manager (the GKE add-on
   mounts secrets as files but does not sync them into a K8s Secret — see
   `03-secretproviderclass.yaml`). Must exist before the pods start:
   ```bash
   ./k8s/create-app-secrets.sh      # idempotent; re-run after rotating a secret
   ```

5. **Deploy** (pin the SHA into image tags, `CUBER_RELEASE_VERSION`, and the migrate
   Job name, then apply):
   ```bash
   sed -i '' "s/GITSHA/$SHA/g" k8s/*.yaml      # macOS sed; use sed -i on Linux/CI
   kubectl apply -f k8s/
   kubectl -n attendee wait --for=condition=complete job/attendee-migrate-$SHA --timeout=600s
   kubectl -n attendee rollout status deployment/attendee-web --timeout=600s
   ```

6. **First admin user / API key** (for testing): create a superuser + a project/API key
   via `python manage.py shell` (see `TEST_PLAN.md` step 2), then manage them in the
   admin UI at `https://attendee.capturemeet.dev` once DNS + cert are live.

## Validation (deployment acceptance)

- `kubectl -n attendee get deploy,po,svc,ingress,job` healthy; cert `Active`;
  `https://attendee.capturemeet.dev/health/` → 200.
- `POST /api/v1/bots` (recording) → a bot pod appears on `attendee-bots`
  (`kubectl get po -n attendee -o wide`; the pool scales 0→1), joins a test Google
  Meet, recording lands in `gs://lynkk-attendee-recordings`, pod deleted at end, node
  scales back to 0.
- **2-way**: bot-create with `websocket_settings.audio.url=wss://…` against a test WS
  echo → inbound `realtime_audio.mixed`, accepted `realtime_audio.bot_output`.

## Open items / gotchas

- **Cost**: idle cost is one `e2-standard-2` control node + `db-g1-small` + the GCLB
  forwarding rule + static IP. The bot pool is min-0, so bot nodes only exist during
  meetings. Scale up (`n2` bots, more control CPU) only after a load test.
- **DB SSL**: `production-gke.py` forces `ssl_require=True`; the private-IP design
  satisfies it (real TLS to Cloud SQL).
- **Bot resources**: `BOT_CPU_REQUEST=2`, `BOT_MEMORY_REQUEST=4Gi` → one bot per
  `e2-standard-4` node. Re-pin from a real load test.
- **Transcription**: send `transcription_settings={"meeting_closed_captions": {}}` on
  bot-create if you don't want a 3rd-party STT provider.
- **CI**: `.github/workflows/deploy-gke.yml` is present but **not wired** for
  lynkk-502014 — it needs a WIF pool + `gha-deploy` SA in the project first. Until
  then, deploy out-of-band with the steps above.
