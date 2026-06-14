# Attendee on GKE — deployment runbook

Self-hosts Attendee as a **separate service** on the existing `meet-cluster`
(`capturemeet` / `asia-south1`), alongside MeetingBaas. Mirrors the meet_transcriber
ops stack (raw manifests + `kubectl` + Workload Identity, Secret Manager CSI, GAR).
Covers **both** recording and the 2-way conversation bot. STT stays in
meet_transcriber (Ringg) — Attendee's transcription is not relied on.

## Architecture

- **Control plane** (`attendee-control` pool, `e2-standard-4`): `attendee-web`
  (gunicorn), `attendee-worker` (celery), `attendee-scheduler`, `redis`.
- **Bot pods** (`attendee-bots` pool, autoscaled `n2-standard-16`, tainted): one
  ephemeral pod per meeting, created by the control plane via the k8s API
  (`LAUNCH_BOT_METHOD=kubernetes`), torn down at meeting end. Targeted onto the pool
  by the `BOT_POD_SPEC_DEFAULT` nodeSelector/toleration patch in `02-configmap.yaml`.
- **Postgres**: Cloud SQL `attendee-pg` on a **private IP**, direct `sslmode=require`
  (no proxy — works for the dynamic bot pods too).
- **Redis**: in-cluster (`04-redis.yaml`).
- **Storage**: native GCS via Workload Identity (no keys; signed URLs via IAM
  SignBlob). Attendee is patched with a django-storages GCS backend (`base.py`,
  `STORAGE_PROTOCOL=gcs`) since the org policy blocks SA/HMAC keys. The final
  recording mp4 uploads via a `gcs` peer to Attendee's azure/s3 uploaders
  (`bots/bot_controller/gcs_file_uploader.py`).
- **Maintenance**: `k8s/10-cronjobs.yaml` reaps completed bot pods + stuck bots
  every 5 min (upstream ships these as commands but doesn't schedule them).
- **CI/CD**: `.github/workflows/deploy-gke.yml` builds on Cloud Build and rolls out
  on push to `main` (WIF authorized for `shreyas-085/{meet_transcriber,attendee}`).

## One-time bring-up

1. **Provision GCP infra** — review then run section-by-section:
   ```bash
   ./k8s/provision.sh
   ```
   Captures: Artifact Registry repo, GCS bucket, `attendee-app` SA + IAM + Workload
   Identity (+ self serviceAccountTokenCreator for signed URLs), Cloud SQL private-IP
   Postgres, Secret Manager secrets, the two node pools, and the global static IP.
   **Manual sub-step it prints:** point the `attendee.capturemeet.dev` DNS A record at
   the static IP (needed before the managed cert provisions).

2. **Cluster-scoped bootstrap** (once):
   ```bash
   kubectl apply -f k8s/bootstrap/      # namespace
   ```
   The Secret Manager CSI sync ClusterRole/Binding is already present cluster-wide
   (applied for meet_transcriber) — it covers the `attendee` namespace too.

3. **Build & push the image** (manual until CI WIF is authorized for this repo):
   ```bash
   SHA=$(git rev-parse --short HEAD)
   IMG=asia-south1-docker.pkg.dev/capturemeet/attendee/attendee
   gcloud auth configure-docker asia-south1-docker.pkg.dev --quiet
   docker build -t "$IMG:$SHA" -t "$IMG:latest" .
   docker push "$IMG:$SHA"; docker push "$IMG:latest"
   ```

4. **Deploy** (pin the SHA into image tags, `CUBER_RELEASE_VERSION`, and the migrate
   Job name, then apply):
   ```bash
   gcloud container clusters get-credentials meet-cluster --zone asia-south1-a
   sed -i '' "s/GITSHA/$SHA/g" k8s/*.yaml      # macOS sed; use sed -i on Linux/CI
   kubectl apply -f k8s/
   kubectl -n attendee wait --for=condition=complete job/attendee-migrate-$SHA --timeout=300s
   kubectl -n attendee rollout status deployment/attendee-web --timeout=300s
   ```

5. **First admin user / API key** (for testing): `kubectl -n attendee exec deploy/attendee-web
   -- python manage.py createsuperuser`, then create a project + API key in the admin UI
   at `https://attendee.capturemeet.dev`.

## Validation (deployment acceptance)

- `kubectl -n attendee get deploy,po,svc,ingress,job` healthy; cert `Active`;
  `https://attendee.capturemeet.dev/health/` → 200.
- `POST /api/v1/bots` (recording) → a bot pod appears on `attendee-bots`
  (`kubectl get po -n attendee -o wide`), joins a test Google Meet, recording lands in
  `gs://capturemeet-attendee-recordings`, pod deleted at end.
- **2-way**: bot-create with `websocket_settings.audio.url=wss://…` against a test WS
  echo → inbound `realtime_audio.mixed`, accepted `realtime_audio.bot_output`.
- Drive >1 node of concurrency → autoscaler adds a bot node, then scales down.
- Measure real per-bot CPU/RAM → set `BOT_CPU_REQUEST` and re-pin the bot node size.

## Open items / gotchas

- **DB SSL**: `production-gke.py` forces `ssl_require=True`; the private-IP design
  satisfies it (real TLS to Cloud SQL). If you ever switch to a localhost proxy, that
  flag will break the plaintext localhost hop.
- **Bot CPU default is 4 cores** in Attendee; we start at `BOT_CPU_REQUEST=2` — confirm
  via load test (drives bot-pool density + cost).
- **CI**: wired — `deploy-gke.yml` builds on Cloud Build + rolls out on push to
  `main`. The manual steps above remain valid for out-of-band deploys.
- **Transcription**: send `transcription_settings={"meeting_closed_captions": {}}` on
  bot-create (no 3rd-party STT) — we transcribe the recording with Ringg downstream.
- **`n2-standard-16`** must be available in `asia-south1-a`; else switch the bot pool
  to `n2`/`e2` in `provision.sh`.

## meet_transcriber integration — separate task

Not done here. Needs: `AttendeeProvider(BotProvider, SpeakingBotProvider)` +
`build_provider` branch + `ATTENDEE_*` settings; an Attendee webhook route; a pipecat
serializer for Attendee's `realtime_audio.*` frames; and per-user `bot_provider` routing
(mirror `stt_provider`). Contract is mapped in the plan.
