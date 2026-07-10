# Attendee Integration

How to drive this **Attendee** deployment (self-hosted on `lynkk-502014` / GKE) from an
external Python service — e.g. the Ringg calling-agent backend. Attendee sends a bot into
Zoom / Google Meet / Microsoft Teams meetings to **record, transcribe, speak, stream, and
run a voice agent**.

- **Live base URL:** `https://attendee.capturemeet.dev`
- **API prefix:** `/api/v1`
- **Auth:** every request needs the header `Authorization: Token <API_KEY>`
- **Interactive reference:** the canonical OpenAPI spec lives at `docs/openapi.yml`
  (rendered at https://docs.attendee.dev).

---

## 1. Credentials

Auth: every request needs the header `Authorization: Token <API_KEY>`.

Credentials are **not** stored in this doc. Get the API key, its project id, and the
per-project webhook signing secret from the Attendee dashboard
(`https://attendee.capturemeet.dev` → Settings → API Keys / Webhooks) or from your own
secret store, and inject them via env vars. Attendee stores only a SHA-256 hash of a
key, so a lost key cannot be recovered — mint a new one.

```bash
# consumer service .env  (fill from your secret store — do NOT commit real values)
ATTENDEE_BASE_URL=https://attendee.capturemeet.dev
ATTENDEE_API_KEY=            # from dashboard → Settings → API Keys
ATTENDEE_WEBHOOK_SECRET=     # per-project, from dashboard → Settings → Webhooks
```

Every API key is scoped to one Project. Bots, transcripts, recordings, calendars,
webhooks and the webhook signing secret are all per-project.

---

## 2. Quickstart

```bash
curl -X POST https://attendee.capturemeet.dev/api/v1/bots \
  -H "Authorization: Token $ATTENDEE_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "meeting_url": "https://us05web.zoom.us/j/123456789?pwd=abcd",
    "bot_name": "Ringg Notetaker"
  }'
```

Response (`201 Created`) returns a `Bot` whose `id` (e.g. `bot_xxx`) you use for every
follow-up call:

```json
{
  "id": "bot_3aFh9...",
  "meeting_url": "https://us05web.zoom.us/j/123456789?pwd=abcd",
  "state": "joining",
  "transcription_state": "not_started",
  "recording_state": "not_started",
  "events": [],
  "join_at": null,
  "metadata": {},
  "deduplication_key": null
}
```

---

## 3. Reusable async client (`aiohttp`)

For the consumer service (e.g. drop into `calling/attendee_client.py`).

```python
import os
from typing import Any
import aiohttp


class AttendeeError(Exception):
    def __init__(self, status: int, body: Any):
        super().__init__(f"Attendee API {status}: {body}")
        self.status = status
        self.body = body


class AttendeeClient:
    """Thin async wrapper over the Attendee REST API."""

    def __init__(
        self,
        base_url: str | None = None,
        api_key: str | None = None,
        session: aiohttp.ClientSession | None = None,
    ):
        self.base_url = (base_url or os.environ["ATTENDEE_BASE_URL"]).rstrip("/")
        self.api_key = api_key or os.environ["ATTENDEE_API_KEY"]
        self._session = session
        self._owns_session = session is None

    async def __aenter__(self):
        if self._session is None:
            self._session = aiohttp.ClientSession()
        return self

    async def __aexit__(self, *exc):
        if self._owns_session and self._session:
            await self._session.close()

    @property
    def _headers(self) -> dict[str, str]:
        return {
            "Authorization": f"Token {self.api_key}",
            "Content-Type": "application/json",
        }

    async def _request(self, method: str, path: str, **kw) -> Any:
        url = f"{self.base_url}/api/v1{path}"
        async with self._session.request(method, url, headers=self._headers, **kw) as r:
            body = await r.json() if r.content_type == "application/json" else await r.text()
            if r.status >= 400:
                raise AttendeeError(r.status, body)
            return body

    # ---- bots ----
    async def create_bot(self, meeting_url: str, bot_name: str, **opts) -> dict:
        payload = {"meeting_url": meeting_url, "bot_name": bot_name, **opts}
        return await self._request("POST", "/bots", json=payload)

    async def get_bot(self, bot_id: str) -> dict:
        return await self._request("GET", f"/bots/{bot_id}")

    async def list_bots(self, **params) -> dict:
        return await self._request("GET", "/bots", params=params)

    async def update_bot(self, bot_id: str, **fields) -> dict:
        return await self._request("PATCH", f"/bots/{bot_id}", json=fields)

    async def delete_bot(self, bot_id: str) -> Any:               # scheduled bots only
        return await self._request("DELETE", f"/bots/{bot_id}")

    async def leave(self, bot_id: str) -> dict:
        return await self._request("POST", f"/bots/{bot_id}/leave")

    async def get_transcript(self, bot_id: str, **params) -> list:
        return await self._request("GET", f"/bots/{bot_id}/transcript", params=params)

    async def get_recording(self, bot_id: str) -> dict:
        return await self._request("GET", f"/bots/{bot_id}/recording")

    async def speak(self, bot_id: str, text: str, tts_settings: dict) -> Any:
        body = {"text": text, "text_to_speech_settings": tts_settings}
        return await self._request("POST", f"/bots/{bot_id}/speech", json=body)

    async def send_chat_message(self, bot_id: str, text: str, to: str = "everyone") -> Any:
        return await self._request(
            "POST", f"/bots/{bot_id}/send_chat_message", json={"text": text, "to": to}
        )

    async def pause_recording(self, bot_id: str) -> Any:
        return await self._request("POST", f"/bots/{bot_id}/pause_recording")

    async def resume_recording(self, bot_id: str) -> Any:
        return await self._request("POST", f"/bots/{bot_id}/resume_recording")

    async def set_voice_agent(self, bot_id: str, *, url: str | None = None,
                              screenshare_url: str | None = None) -> dict:
        body = {k: v for k, v in {"url": url, "screenshare_url": screenshare_url}.items() if v}
        return await self._request("PATCH", f"/bots/{bot_id}/voice_agent_settings", json=body)
```

Usage:

```python
async with AttendeeClient() as attendee:
    bot = await attendee.create_bot(
        meeting_url="https://meet.google.com/abc-defg-hij",
        bot_name="Ringg Notetaker",
        metadata={"ringg_call_id": "call_123"},
    )
    transcript = await attendee.get_transcript(bot["id"])
```

---

## 4. Full endpoint reference

Base path for all rows: `https://attendee.capturemeet.dev/api/v1`. All require
`Authorization: Token <API_KEY>`.

### Bots

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/bots` | Create a bot (joins now, or schedule with `join_at`) |
| `GET` | `/bots` | List bots in the project (paginated) |
| `GET` | `/bots/{id}` | Get bot detail + lifecycle `events` |
| `PATCH` | `/bots/{id}` | Update a bot (e.g. a scheduled bot's settings) |
| `DELETE` | `/bots/{id}` | Delete a **scheduled** bot |
| `POST` | `/bots/{id}/leave` | Make the bot leave the meeting |
| `GET` | `/bots/{id}/transcript` | Transcript utterances (see §6) |
| `GET` | `/bots/{id}/recording` | Recording download URL (see §6) |
| `GET` | `/bots/{id}/participants` | Participants seen in the meeting |
| `GET` | `/bots/{id}/participant_events` | Join/leave + speech start/stop events |
| `GET` | `/bots/{id}/chat_messages` | In-meeting chat messages captured |
| `POST` | `/bots/{id}/send_chat_message` | Send a chat message (`{"text","to"}`) |
| `POST` | `/bots/{id}/speech` | Speak TTS audio into the meeting (see §7) |
| `POST` | `/bots/{id}/output_audio` | Play raw audio into the meeting |
| `POST` | `/bots/{id}/output_image` | Set the bot's webcam image |
| `POST` | `/bots/{id}/output_video` | Play a video into the meeting |
| `POST` | `/bots/{id}/pause_recording` | Pause recording |
| `POST` | `/bots/{id}/resume_recording` | Resume recording |
| `PATCH` | `/bots/{id}/voice_agent_settings` | Point the bot's voice agent at a `url` |
| `POST` | `/bots/{id}/delete_data` | Permanently delete recordings/transcripts |

### Calendars (auto-join scheduled meetings)

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/calendars` | List connected calendars |
| `POST` | `/calendars` | Connect a calendar |
| `GET` | `/calendars/{id}` | Calendar detail |
| `PATCH` | `/calendars/{id}` | Update calendar |
| `DELETE` | `/calendars/{id}` | Disconnect calendar |
| `GET` | `/calendar_events` | List calendar events (filter to attach bots) |

### Zoom OAuth connections (for native Zoom apps / RTMS)

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/zoom_oauth_connections` | List connections |
| `POST` | `/zoom_oauth_connections` | Create a connection |
| `GET` | `/zoom_oauth_connections/{id}` | Get a connection |
| `DELETE` | `/zoom_oauth_connections/{id}` | Delete a connection |

---

## 5. Creating a bot — full payload

Only `meeting_url` and `bot_name` are required. Everything else is optional.

```jsonc
{
  "meeting_url": "https://zoom.us/j/123?pwd=456",   // required
  "bot_name": "Ringg Notetaker",                    // required

  "metadata": { "ringg_call_id": "call_123" },      // echoed back + in webhooks
  "join_at": "2026-06-20T15:00:00Z",                // ISO 8601 → schedules the bot
  "deduplication_key": "call_123",                  // dedupe: reuse instead of dup
  "calendar_event_id": "evt_...",                   // attach to a calendar event

  "bot_image": { "type": "image/png", "data": "<base64>" },
  "bot_chat_message": { "to": "everyone", "message": "Recording for Ringg" },

  "transcription_settings": { "deepgram": { "language": "en" } },
  "recording_settings": { "format": "mp4", "view": "speaker_view" },
  "voice_agent_settings": { "url": "wss://your-agent.example/agent" },

  "webhooks": [                                     // per-bot webhook subscriptions
    { "url": "https://your-svc/attendee/webhook",
      "triggers": ["bot.state_change", "transcript.update"] }
  ],
  "callback_settings": { },
  "external_media_storage_settings": { },
  "websocket_settings": { "audio": { "url": "wss://example/audio" } },
  "rtmp_settings": { "destination_url": "rtmp://global-live.../key" },

  "google_meet_settings": { },
  "teams_settings": { },
  "zoom_settings": { },
  "automatic_leave_settings": { },
  "debug_settings": { "create_debug_recording": true }
}
```

### Bot lifecycle `state` values

`ready` → `joining` → `joined_not_recording` / `joined_recording` → `leaving` →
`post_processing` → `ended`. Other states: `waiting_room`, `joined_recording_paused`,
`joined_recording_permission_denied`, `joining_breakout_room`, `leaving_breakout_room`,
`scheduled`, `staged`, `fatal_error`, `data_deleted`.

Recordings and transcripts are only fully available once the bot reaches **`ended`** —
the cleanest trigger is the `bot.state_change` webhook (§8), not polling.

---

## 6. Getting results

### Transcript — `GET /bots/{id}/transcript`
Returns an array of utterances:

```json
[
  {
    "speaker_name": "Alice",
    "speaker_uuid": "16778240",
    "speaker_user_uuid": "abc-123",
    "speaker_is_host": true,
    "timestamp_ms": 12000,
    "duration_ms": 3400,
    "transcription": { "transcript": "Hello everyone" }
  }
]
```

### Recording — `GET /bots/{id}/recording`
```json
{ "url": "https://storage.googleapis.com/...signed...", "start_timestamp_ms": 1718895600000 }
```
`url` is a time-limited signed URL (GCS V4) — download/copy it promptly, don't store it.

Both `transcript` and `recording` are most reliably fetched **after** the
`bot.state_change` webhook reports `ended`.

---

## 7. Speaking & media output

```python
await attendee.speak(
    bot_id,
    text="Thanks for joining, the call is now being recorded.",
    tts_settings={"provider": "openai", "openai": {"voice": "alloy"}},
)
```
- `POST /bots/{id}/speech` — body `{"text", "text_to_speech_settings"}`.
- `POST /bots/{id}/output_audio` — play raw audio bytes.
- `POST /bots/{id}/output_image` — set webcam image.
- `PATCH /bots/{id}/voice_agent_settings` — body `{"url", "screenshare_url"}`; point the
  bot at a websocket voice-agent endpoint for 2-way conversation.

---

## 8. Webhooks (recommended over polling)

Subscribe per-bot (the `webhooks` field at create time) or project-wide in the
dashboard. Attendee `POST`s JSON to your URL on these triggers:

| Trigger | Fires when |
|---|---|
| `bot.state_change` | Bot transitions state (e.g. reaches `ended`) |
| `transcript.update` | New transcript utterance is available |
| `chat_messages.update` | A chat message was captured |
| `participant_events.join_leave` | Participant joins/leaves |
| `participant_events.speech_start_stop` | Participant starts/stops speaking |

### Verifying the signature
Each request carries an `X-Webhook-Signature` header = base64(HMAC-SHA256(body, secret)).
The **per-project webhook secret** is base64-encoded and lives in the dashboard under
**Settings → Webhooks** (`https://attendee.capturemeet.dev`). Store it as
`ATTENDEE_WEBHOOK_SECRET`.

FastAPI receiver (for the consumer service):

```python
import base64, hashlib, hmac, json, os
from fastapi import APIRouter, Request, HTTPException

router = APIRouter()
_SECRET = base64.b64decode(os.environ["ATTENDEE_WEBHOOK_SECRET"])


def _expected_sig(raw_body: bytes) -> str:
    # Attendee signs the canonical JSON (sorted, compact) — re-serialize to match.
    payload = json.dumps(json.loads(raw_body), separators=(",", ":"), sort_keys=True)
    digest = hmac.new(_SECRET, payload.encode(), hashlib.sha256).digest()
    return base64.b64encode(digest).decode()


@router.post("/attendee/webhook")
async def attendee_webhook(request: Request):
    raw = await request.body()
    sig = request.headers.get("X-Webhook-Signature", "")
    if not hmac.compare_digest(sig, _expected_sig(raw)):
        raise HTTPException(status_code=401, detail="bad signature")

    event = json.loads(raw)
    trigger = event.get("trigger")          # e.g. "bot.state_change"
    bot_id = event.get("bot_id")
    data = event.get("data", {})
    # route on trigger; e.g. when data["new_state"] == "ended" → fetch transcript/recording
    return {"ok": True}
```

> Match the signed-string format to Attendee's `sign_payload` helper in `docs/webhooks.md`
> if verification fails (whitespace/key-ordering must match exactly). Return `2xx` quickly
> and process async; Attendee retries non-2xx.

---

## 9. Errors, pagination, rate limits

- **Auth errors** → `401` with `{"detail": "..."}` (missing/invalid `Authorization`, or
  disabled key). Header format is exactly `Token <key>` (the word `Token`, a space, the key).
- **Validation errors** → `400` with field-level messages.
- **Not found** → `404` JSON.
- **Pagination** (`GET` list endpoints) → `{ "results": [...], "next": <url|null>,
  "previous": <url|null> }`. Follow `next` to page.
- **Rate limit** → `429`. The project POST throttle defaults to **3000/min**. Back off and
  retry on `429`.

---

## 10. Integration notes

- Pass `metadata` (e.g. `{"ringg_call_id": ...}`) on bot creation so webhook payloads
  correlate back to the calling-agent call/session without a side lookup.
- Use `deduplication_key` (e.g. the Ringg call id) to make "start a bot" idempotent —
  retries won't spawn duplicate bots.
- Prefer the `bot.state_change` webhook reaching `ended` to trigger transcript/recording
  fetch; the recording `url` is a short-lived signed URL, so download it on receipt.
- Need the webhook secret or a dedicated project/key for the consumer service instead of
  the shared admin project? Both are quick to provision — ask.
```
