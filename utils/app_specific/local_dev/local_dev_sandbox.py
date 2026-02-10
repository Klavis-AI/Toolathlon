"""Upload/download workspace files to/from a Klavis local_dev sandbox.

Upload flow (3 steps via GCS signed URLs):
  1. POST /upload-url  → get a signed GCS PUT URL
  2. PUT the tar.gz directly to GCS
  3. POST /initialize  → tell the server to extract from GCS into the pod

Download flow (streaming):
  GET /dump → streamed tar.gz response
"""

import io
import os
import tarfile
from pathlib import Path
from typing import Optional

import httpx

KLAVIS_API_BASE = "https://api.klavis.ai"


def _collect_files(directory: str):
    """Yield (relative_path, absolute_path) for every file under *directory*."""
    root = Path(directory)
    for path in root.rglob("*"):
        if path.is_file():
            yield str(path.relative_to(root)), str(path)


def _get_signed_upload_url(sandbox_id: str, api_key: str, timeout: int = 120) -> str:
    """Request a signed GCS upload URL from the API."""
    headers = {"Authorization": f"Bearer {api_key}"}
    resp = httpx.post(
        f"{KLAVIS_API_BASE}/sandbox/local_dev/{sandbox_id}/upload-url",
        headers=headers,
        timeout=timeout,
    )
    resp.raise_for_status()
    return resp.json()["upload_url"]


def _upload_to_gcs(upload_url: str, content: bytes, timeout: int = 120) -> None:
    """PUT a tar.gz archive directly to the signed GCS URL."""
    resp = httpx.put(
        upload_url,
        headers={"Content-Type": "application/gzip"},
        content=content,
        timeout=timeout,
    )
    resp.raise_for_status()


def _trigger_initialize(sandbox_id: str, api_key: str, timeout: int = 120) -> dict:
    """POST /initialize to tell the server to extract the GCS archive into the pod."""
    headers = {"Authorization": f"Bearer {api_key}"}
    resp = httpx.post(
        f"{KLAVIS_API_BASE}/sandbox/local_dev/{sandbox_id}/initialize",
        headers=headers,
        timeout=timeout,
    )
    resp.raise_for_status()
    return resp.json()


def upload_workspace(sandbox_id: str, directory: str, api_key: str, timeout: int = 120) -> dict:
    """Upload all files in *directory* to the local_dev sandbox.

    1. Builds a tar.gz in memory from *directory*.
    2. Gets a signed GCS upload URL.
    3. PUTs the archive to GCS.
    4. Calls /initialize to extract the archive into the pod.
    """
    collected = list(_collect_files(directory))
    if not collected:
        return {"sandbox_id": sandbox_id, "status": "idle", "message": "No files to upload"}

    # Build an in-memory tar.gz archive preserving directory structure
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for rel_path, abs_path in collected:
            info = tar.gettarinfo(abs_path, arcname=rel_path)
            with open(abs_path, "rb") as f:
                tar.addfile(info, f)
    content = buf.getvalue()

    upload_url = _get_signed_upload_url(sandbox_id, api_key, timeout=timeout)
    _upload_to_gcs(upload_url, content, timeout=timeout)
    return _trigger_initialize(sandbox_id, api_key, timeout=timeout)


def upload_workspace_tarball(sandbox_id: str, tarball_path: str, api_key: str, timeout: int = 120) -> dict:
    """Upload a pre-built tar.gz file to the local_dev sandbox.

    1. Gets a signed GCS upload URL.
    2. PUTs the tarball to GCS.
    3. Calls /initialize to extract the archive into the pod.
    """
    with open(tarball_path, "rb") as f:
        content = f.read()

    if not content:
        return {"sandbox_id": sandbox_id, "status": "idle", "message": "Empty tarball"}

    upload_url = _get_signed_upload_url(sandbox_id, api_key, timeout=timeout)
    _upload_to_gcs(upload_url, content, timeout=timeout)
    return _trigger_initialize(sandbox_id, api_key, timeout=timeout)


def download_workspace(sandbox_id: str, directory: str, api_key: str, timeout: int = 120) -> None:
    """Download all files from the local_dev sandbox into *directory*.

    1. ``GET /sandbox/local_dev/{sandbox_id}/dump`` → JSON with a signed GCS download URL.
    2. ``GET <download_url>`` → stream the tar.gz from GCS and extract into *directory*.
    """
    headers = {"Authorization": f"Bearer {api_key}"}

    os.makedirs(directory, exist_ok=True)

    # Step 1: Get signed download URL from the API
    resp = httpx.get(
        f"{KLAVIS_API_BASE}/sandbox/local_dev/{sandbox_id}/dump",
        headers=headers,
        timeout=timeout,
    )
    resp.raise_for_status()
    download_url = resp.json()["download_url"]

    # Step 2: Download the tar.gz from GCS and extract
    with httpx.stream("GET", download_url, timeout=timeout) as dl_resp:
        dl_resp.raise_for_status()

        buf = io.BytesIO()
        for chunk in dl_resp.iter_bytes():
            buf.write(chunk)
        buf.seek(0)

        with tarfile.open(fileobj=buf, mode="r:gz") as tar:
            tar.extractall(path=directory, filter="data")


def get_local_dev_sandbox_id(klavis_client) -> Optional[str]:
    """Extract the local_dev sandbox_id from a KlavisSandbox client, if any."""
    for sandbox in klavis_client.acquired_sandboxes:
        if sandbox.get("server_name") == "local_dev":
            return sandbox.get("sandbox_id")
    return None
