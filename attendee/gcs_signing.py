"""Keyless V4 signed URLs for GCS under Workload Identity.

Workload-Identity / compute credentials carry only an access token (no private
key), so google-cloud-storage cannot sign V4 URLs locally and raises
"you need a private key to sign credentials". Passing the SA email + a fresh
access token to ``generate_signed_url`` makes it sign via the IAM SignBlob API
instead. The runtime SA needs ``roles/iam.serviceAccountTokenCreator`` on itself
and the IAM Credentials API enabled.
"""

import google.auth
from google.auth.transport.requests import Request
from storages.backends.gcloud import GoogleCloudStorage
from storages.utils import clean_name


class SignedGoogleCloudStorage(GoogleCloudStorage):
    """GoogleCloudStorage whose ``url()`` signs via IAM SignBlob (no key file)."""

    def url(self, name: str) -> str:
        name = self._normalize_name(clean_name(name))
        blob = self.bucket.blob(name)
        credentials, _ = google.auth.default()
        credentials.refresh(Request())
        return blob.generate_signed_url(
            version="v4",
            expiration=self.expiration,
            service_account_email=credentials.service_account_email,
            access_token=credentials.token,
        )
