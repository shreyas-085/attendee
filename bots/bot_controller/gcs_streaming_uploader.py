"""Stream a recording to Google Cloud Storage *while* it is being recorded.

`GcsResumableUpload` implements the GCS resumable-upload protocol
(https://cloud.google.com/storage/docs/performing-resumable-uploads) directly over an
authorized session, so bytes can be committed incrementally as they are produced — unlike
`GcsFileUploader`, which uploads a finished file in one shot. Auth is keyless Application
Default Credentials (the pod's Workload-Identity SA), the same as `GcsFileUploader`.

`RecordingStreamUploader` wires that to the recording: a background thread tails the growing
local recording file, feeds new bytes to the resumable upload in 256 KiB-multiple chunks
(the GCS requirement for non-final chunks), and finalizes when recording stops — so the
object is complete within seconds of the meeting ending.
"""

import logging
import os
import threading
import time
from urllib.parse import quote

import google.auth
from google.auth.transport.requests import AuthorizedSession

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

# GCS requires every non-final resumable chunk to be a multiple of 256 KiB.
GCS_CHUNK_MULTIPLE = 256 * 1024
_RESUMABLE_SCOPE = "https://www.googleapis.com/auth/devstorage.read_write"


class GcsResumableUpload:
    """Incremental resumable upload of a single object to GCS.

    Usage: start() -> upload_part(bytes) repeatedly -> finalize(). All non-final chunks sent
    to GCS are trimmed to a multiple of 256 KiB; the remainder is carried in an internal
    buffer until the next part or finalize.
    """

    def __init__(self, bucket, object_name, flush_threshold=8 * 1024 * 1024, chunk_multiple=GCS_CHUNK_MULTIPLE):
        if not bucket or not object_name:
            raise ValueError("Both 'bucket' and 'object_name' are required")
        self.bucket = bucket
        self.object_name = object_name
        self.chunk_multiple = chunk_multiple
        # Only PUT once at least this many bytes have accumulated, to keep request count low
        # (rounded down to a 256 KiB multiple when sent).
        self.flush_threshold = max(flush_threshold, chunk_multiple)
        self._buffer = bytearray()
        self._bytes_committed = 0  # total bytes GCS has acknowledged
        self._session_uri = None
        self._finalized = False

        credentials, _ = google.auth.default(scopes=[_RESUMABLE_SCOPE])
        self._session = AuthorizedSession(credentials)

    def start(self):
        """Open a resumable session and remember its upload URI."""
        url = f"https://storage.googleapis.com/upload/storage/v1/b/{self.bucket}/o?uploadType=resumable&name={quote(self.object_name, safe='')}"
        resp = self._session.post(url, headers={"Content-Length": "0"})
        if resp.status_code not in (200, 201):
            raise RuntimeError(f"Failed to start GCS resumable upload ({resp.status_code}): {resp.text}")
        self._session_uri = resp.headers["Location"]
        logger.info(f"Started GCS resumable upload for gs://{self.bucket}/{self.object_name}")

    def upload_part(self, data: bytes):
        """Buffer `data`; once past the flush threshold, PUT a 256 KiB-aligned chunk."""
        if self._finalized:
            raise RuntimeError("upload_part called after finalize")
        self._buffer.extend(data)
        if len(self._buffer) < self.flush_threshold:
            return

        # Flush everything except a trailing remainder, aligned to the chunk multiple. Keep at
        # least one multiple back so the very last chunk (which carries the total size) is sent
        # by finalize(), never here.
        flushable = len(self._buffer)
        aligned = (flushable // self.chunk_multiple) * self.chunk_multiple
        if aligned == flushable and aligned > 0:
            aligned -= self.chunk_multiple  # never send the tail as an intermediate chunk
        if aligned <= 0:
            return

        chunk = bytes(self._buffer[:aligned])
        del self._buffer[:aligned]
        self._send_chunk(chunk, final=False)

    def finalize(self):
        """Send the remaining buffered bytes as the final chunk and complete the object."""
        if self._finalized:
            return
        chunk = bytes(self._buffer)
        self._buffer.clear()
        self._send_chunk(chunk, final=True)
        self._finalized = True
        logger.info(f"Finalized GCS upload gs://{self.bucket}/{self.object_name} ({self._bytes_committed} bytes)")

    @property
    def total_bytes(self):
        return self._bytes_committed

    def _send_chunk(self, chunk: bytes, final: bool, max_retries: int = 5):
        start = self._bytes_committed
        length = len(chunk)

        if final:
            total = start + length
            if length == 0:
                # Zero remaining bytes: tell GCS the final size with an empty body.
                content_range = f"bytes */{total}"
            else:
                content_range = f"bytes {start}-{start + length - 1}/{total}"
        else:
            if length == 0:
                return
            content_range = f"bytes {start}-{start + length - 1}/*"

        attempt = 0
        while True:
            attempt += 1
            try:
                resp = self._session.put(
                    self._session_uri,
                    data=chunk,
                    headers={"Content-Range": content_range},
                )
            except Exception as e:
                if attempt > max_retries:
                    raise
                logger.warning(f"GCS chunk PUT error ({e}); retry {attempt}/{max_retries}")
                self._resync_offset()
                start = self._bytes_committed
                continue

            # 308 = Resume Incomplete (intermediate chunk accepted); 200/201 = object complete.
            if resp.status_code == 308:
                self._bytes_committed = start + length
                return
            if final and resp.status_code in (200, 201):
                self._bytes_committed = start + length
                return

            if attempt > max_retries:
                raise RuntimeError(f"GCS chunk upload failed ({resp.status_code}): {resp.text}")
            logger.warning(f"GCS chunk PUT {resp.status_code}; retry {attempt}/{max_retries}")
            # Re-sync committed offset from GCS before retrying so we don't re-send bytes.
            self._resync_offset()
            if self._bytes_committed >= start + length:
                return  # already committed by a prior partially-succeeded attempt
            start = self._bytes_committed

    def _resync_offset(self):
        """Query GCS for how many bytes it has committed (Range header) after a failure."""
        try:
            resp = self._session.put(self._session_uri, headers={"Content-Range": "bytes */*"})
            if resp.status_code == 308:
                rng = resp.headers.get("Range")
                if rng and rng.startswith("bytes=0-"):
                    self._bytes_committed = int(rng.split("-", 1)[1]) + 1
        except Exception as e:
            logger.warning(f"GCS offset resync failed: {e}")


class RecordingStreamUploader:
    """Tail a growing recording file and stream it to GCS during the meeting.

    start() spawns a daemon thread that waits for the file to appear, then reads and uploads
    new bytes as they are written. stop_and_finalize() signals recording is done, drains the
    final bytes, finalizes the object, and returns True on success (False → caller should fall
    back to the end-of-meeting uploader).
    """

    def __init__(self, bucket, object_name, file_path, poll_interval=0.5, read_size=1024 * 1024, flush_threshold=8 * 1024 * 1024):
        self.upload = GcsResumableUpload(bucket, object_name, flush_threshold=flush_threshold)
        self.object_name = object_name
        self.file_path = file_path
        self.poll_interval = poll_interval
        self.read_size = read_size
        self._stop_event = threading.Event()
        self._thread = None
        self._failed = False
        self._offset = 0

    @property
    def filename(self):
        return self.object_name

    def start(self):
        try:
            self.upload.start()
        except Exception:
            logger.exception("Failed to start GCS resumable session; streaming upload disabled")
            self._failed = True
            return
        self._thread = threading.Thread(target=self._tail_worker, daemon=True)
        self._thread.start()

    def _read_new_bytes(self, f):
        """Read and upload all bytes currently available past our offset."""
        while True:
            f.seek(self._offset)
            data = f.read(self.read_size)
            if not data:
                return
            self.upload.upload_part(data)
            self._offset += len(data)

    def _tail_worker(self):
        try:
            # Wait for the recorder to create the file.
            while not os.path.exists(self.file_path):
                if self._stop_event.is_set():
                    return
                time.sleep(self.poll_interval)

            with open(self.file_path, "rb") as f:
                while not self._stop_event.is_set():
                    self._read_new_bytes(f)
                    time.sleep(self.poll_interval)
                # Recording stopped — read whatever was written after the last poll.
                self._read_new_bytes(f)
        except Exception:
            logger.exception("Streaming upload tailer failed; will fall back to end-of-meeting upload")
            self._failed = True

    def stop_and_finalize(self, timeout=120):
        """Stop tailing, flush the final bytes, and finalize the GCS object.

        Returns True if the object was fully uploaded and finalized, else False.
        """
        if self._failed and self._thread is None:
            return False
        self._stop_event.set()
        if self._thread:
            self._thread.join(timeout=timeout)
            if self._thread.is_alive():
                logger.error("Streaming upload tailer did not finish within timeout")
                return False
        if self._failed:
            return False
        try:
            self.upload.finalize()
        except Exception:
            logger.exception("Failed to finalize streaming GCS upload")
            return False
        return True
