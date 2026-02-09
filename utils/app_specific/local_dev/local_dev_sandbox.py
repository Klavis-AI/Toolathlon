"""Upload/download workspace files to/from a Klavis local_dev sandbox."""

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


def upload_workspace(sandbox_id: str, directory: str, api_key: str, timeout: int = 120) -> dict:
    """Upload all files in *directory* to the local_dev sandbox.

    Calls ``POST /sandbox/local_dev/{sandbox_id}/initialize`` with multipart
    form data containing every file and a ``paths`` field that preserves the
    directory structure.
    """
    files_list = []
    paths_list = []
    for rel_path, abs_path in _collect_files(directory):
        files_list.append(("files", (os.path.basename(abs_path), open(abs_path, "rb"))))
        paths_list.append(rel_path)

    if not files_list:
        return {"sandbox_id": sandbox_id, "status": "idle", "message": "No files to upload"}

    try:
        import json
        headers = {"Authorization": f"Bearer {api_key}"}
        data = {"paths": json.dumps(paths_list)}
        resp = httpx.post(
            f"{KLAVIS_API_BASE}/sandbox/local_dev/{sandbox_id}/initialize",
            headers=headers,
            data=data,
            files=files_list,
            timeout=timeout,
        )
        resp.raise_for_status()
        return resp.json()
    finally:
        # Close all opened file handles
        for _, (_, fh) in files_list:
            fh.close()


def download_workspace(sandbox_id: str, directory: str, api_key: str, timeout: int = 120) -> None:
    """Download all files from the local_dev sandbox into *directory*.

    Calls ``GET /sandbox/local_dev/{sandbox_id}/dump`` which returns a tar
    archive, then extracts it into *directory*.
    """
    headers = {"Authorization": f"Bearer {api_key}"}
    resp = httpx.get(
        f"{KLAVIS_API_BASE}/sandbox/local_dev/{sandbox_id}/dump",
        headers=headers,
        timeout=timeout,
    )
    resp.raise_for_status()

    os.makedirs(directory, exist_ok=True)

    # The response is a tar archive
    buf = io.BytesIO(resp.content)
    with tarfile.open(fileobj=buf, mode="r:*") as tar:
        tar.extractall(path=directory, filter="data")


def get_local_dev_sandbox_id(klavis_client) -> Optional[str]:
    """Extract the local_dev sandbox_id from a KlavisSandbox client, if any."""
    for sb in klavis_client.acquired_sandboxes:
        if sb.get("server_name") == "local_dev":
            return sb.get("sandbox_id")
    return None
