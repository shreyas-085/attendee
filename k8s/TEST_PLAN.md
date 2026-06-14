# Attendee Deployment — End-to-End Test Plan

A step-by-step runbook to prove the self-hosted Attendee service actually works
(the one thing not yet validated: a real bot joining a meeting + recording to GCS).
We run this together — you start a Meet and admit the bot; I drive the API/kubectl.

All API calls go **service-to-service via port-forward** (no public DNS/cert needed):

```bash
# Terminal A — keep this open for the whole test
kubectl -n attendee port-forward deploy/attendee-web 8000:8000
# Then in Terminal B:
BASE=http://localhost:8000
```

---

## Step 1 — Pre-flight (re-confirm green; already validated)

```bash
kubectl -n attendee get deploy            # web/worker/scheduler/redis all 1/1
curl -s -o /dev/null -w "%{http_code}\n" $BASE/health/     # 200
```
**Pass:** all deployments Ready, `/health/` → 200.

---

## Step 2 — Mint an API key (one-time, via shell)

```bash
kubectl -n attendee exec deploy/attendee-web -c web -- python manage.py shell -c "
from accounts.models import Organization
from bots.models import Project, ApiKey
org,_ = Organization.objects.get_or_create(name='capturemeet')
proj,_ = Project.objects.get_or_create(name='meet-transcriber', organization=org)
inst, raw = ApiKey.create(project=proj, name='e2e-test')
print('API_KEY:', raw)
"
```
Save it: `TOKEN=<API_KEY from output>`. *(Raw key is shown once; only a SHA-256 hash is stored.)*
Auth header for every call: **`Authorization: Token $TOKEN`**.

---

## Step 3 — API smoke test (no meeting needed)

```bash
curl -s -H "Authorization: Token $TOKEN" $BASE/api/v1/bots | head -c 300; echo
```
**Pass:** HTTP 200 + a (likely empty) JSON list. This proves the exact auth + API
surface that `meet_transcriber`'s `AttendeeProvider` will call.

---

## Step 4 — Recording bot-join test (the main event) ▶ needs a live Meet

**You:** start a Google Meet, copy its URL, and be ready to **admit "Test Bot"** from
the waiting room. Ideally have a second person speak too (so we see ≥2 speaker names).

**4a. Launch the bot** (audio+video for the first run; we switch to `mp3` audio-only for
production to save storage):
```bash
MEET_URL='<paste the meet url>'
curl -s -X POST $BASE/api/v1/bots \
  -H "Authorization: Token $TOKEN" -H "Content-Type: application/json" \
  -d "{\"meeting_url\":\"$MEET_URL\",\"bot_name\":\"Test Bot\",
       \"metadata\":{\"correlation_id\":\"e2e-1\"},
       \"transcription_settings\":{\"meeting_closed_captions\":{}},
       \"recording_settings\":{\"format\":\"mp4\"}}" | tee /tmp/bot.json
BOT_ID=$(python3 -c "import json;print(json.load(open('/tmp/bot.json'))['id'])")
echo "BOT_ID=$BOT_ID"
```

**4b. Watch the bot pod spawn on the bots pool** (I run this):
```bash
kubectl -n attendee get po -o wide -w | grep -vE "web|worker|scheduler|redis"
# Expect a new pod (name ~ the bot id) on a gke-...-attendee-bots-... node, → Running
```

**4c. Admit the bot** in the Meet. Talk for ~30–60s (two voices if possible).

**4d. Poll state** until recording:
```bash
watch -n 3 "curl -s -H 'Authorization: Token $TOKEN' $BASE/api/v1/bots/$BOT_ID \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[\"state\"],d[\"recording_state\"],d[\"transcription_state\"])'"
# joining → joined_recording  (recording_state: in_progress)
```

**4e. End the call** (host ends the meeting). State should go
`post_processing` → **`ended`**, `recording_state` → **`complete`**.

**4f. Verify the recording landed in GCS:**
```bash
curl -s -H "Authorization: Token $TOKEN" $BASE/api/v1/bots/$BOT_ID/recording | tee /tmp/rec.json
# -> {"url":"https://storage.googleapis.com/...X-Goog-Signature...", "start_timestamp_ms":...}
gcloud storage ls -l "gs://capturemeet-attendee-recordings/" --recursive | tail
```

**4g. Verify speaker data** (this is the diarization-with-real-names our integration maps to):
```bash
curl -s -H "Authorization: Token $TOKEN" $BASE/api/v1/bots/$BOT_ID/transcript    | head -c 600; echo
curl -s -H "Authorization: Token $TOKEN" $BASE/api/v1/bots/$BOT_ID/participants | head -c 400; echo
# transcript utterances carry speaker_name + timestamp_ms + duration_ms
```

**4h. Confirm pod cleanup:** the bot pod is deleted after `ended`.

### Pass criteria (Step 4)
- [ ] Bot pod scheduled on an **`attendee-bots`** node and reached `Running`
- [ ] State reached **`joined_recording`** then **`ended`**
- [ ] `recording` endpoint returns a signed GCS URL; object present in the bucket
- [ ] `transcript`/`participants` carry **real speaker names**
- [ ] Bot pod deleted at end (capacity reclaimed)

---

## Step 5 — Autoscaling (optional)

Launch several concurrent bots (or temporarily set `BOT_CPU_REQUEST` so one node fills),
then watch a second bot node get added and later removed:
```bash
kubectl get nodes -l workload=bot -w     # node count grows under load, shrinks after
```
*(Min stays 1 per your choice, so one bot node is always warm.)*

---

## Step 6 — 2-way conversation WebSocket (optional; conversation-mode gate)

Point a bot at a temporary echo WebSocket and confirm bidirectional PCM:
```bash
# create with: "websocket_settings":{"audio":{"url":"wss://<reachable-echo>/ws","sample_rate":16000}}
# Expect inbound frames trigger=realtime_audio.mixed (base64 PCM); echo back as realtime_audio.bot_output
```
This is the precise interop our pipecat serializer must match — fine to defer to the
integration task, but a quick echo test de-risks it.

---

## Step 7 — Cleanup

```bash
# delete the test bot(s) if still around; remove the test API key/project if desired
kubectl -n attendee exec deploy/attendee-web -c web -- python manage.py shell -c "
from bots.models import ApiKey; ApiKey.objects.filter(name='e2e-test').update(disabled_at=__import__('django').utils.timezone.now())
print('disabled e2e-test key')"
```

---

## Troubleshooting

| Symptom | Likely cause / check |
|---|---|
| Bot pod stuck `Pending` | taint/toleration or node quota → `kubectl describe po <bot> -n attendee` |
| Bot never joins / stuck `joining` | not admitted from waiting room; or Meet bot-detection |
| `recording_state: failed` | GCS perms / SignBlob → `kubectl logs <bot-pod> -n attendee` |
| 401 on API | header must be exactly `Authorization: Token <raw_key>` (lowercase "token") |
| Bot pod image pull error | `BOT_POD_IMAGE`/`CUBER_RELEASE_VERSION` mismatch with a pushed tag |

Bot pod logs (most useful during a failed join):
```bash
kubectl -n attendee logs <bot-pod-name> --tail=100
```
