"""Klavis MCP Sandbox API client."""

import os
import httpx
from typing import Dict, Optional, List


KLAVIS_API_BASE = "https://api.klavis.ai"

# Task server names that should be acquired via a single "local_dev" sandbox.
LOCAL_DEV_SERVER_NAMES = {
    "filesystem", "git", "terminal", "python_execute",
    "pdf-tools", "excel", "word", "pptx", "arxiv_local",
}

# Mapping from task server name -> key returned in the local_dev server_urls response.
# Only entries that differ need to be listed; identical names are handled automatically.
LOCAL_DEV_TASK_TO_REMOTE_NAME = {
    "python_execute": "code-executor",
    "pptx": "powerpoint",
    "arxiv_local": "arxiv",
}

# Mapping from task server name -> sandbox server name to acquire.
TASK_SERVER_TO_SANDBOX_NAME = {
    "arxiv-latex": "arxiv_latex",
    "google_sheet": "google_sheets",
    "wandb": "weights_and_biases",
    "emails": "poste_email_toolathlon",
}


class KlavisSandbox:
    def __init__(self, api_key: str = None):
        self.api_key = api_key or os.environ.get("KLAVIS_API_KEY")
        if not self.api_key:
            raise ValueError("KLAVIS_API_KEY is required")
        self.acquired_sandboxes: List[Dict] = []

    def acquire(self, server_name: str, extra_params: Optional[Dict] = None) -> Optional[Dict]:
        """Acquire a sandbox for a given MCP server.
        
        Args:
            server_name: The name of the server to acquire a sandbox for.
            extra_params: Optional extra parameters to include in the request body.
        
        Returns response dict with sandbox_id, server_urls, etc. or None on failure.
        """
        url = f"{KLAVIS_API_BASE}/sandbox/{server_name}"
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
        }
        body = {"benchmark": "Toolathlon"}
        if extra_params:
            body.update(extra_params)
        try:
            resp = httpx.post(url, json=body, headers=headers, timeout=60)
            resp.raise_for_status()
            data = resp.json()
            self.acquired_sandboxes.append(data)
            return data
        except Exception as e:
            print(f"[Klavis] Failed to acquire sandbox for '{server_name}': {e}")
            return None

    def acquire_for_servers(self, server_names: List[str], server_extra_params: Optional[Dict[str, Dict]] = None) -> Dict[str, str]:
        """Acquire sandboxes for multiple servers.
        
        Args:
            server_names: List of server names to acquire sandboxes for.
            server_extra_params: Optional dict mapping server_name -> extra params
                to include in the acquire request body for that server.
        
        Returns a dict mapping server_name -> streamable-http URL for servers
        that were successfully acquired. Servers that fail are silently skipped.

        Server names belonging to LOCAL_DEV_SERVER_NAMES are grouped and
        acquired via a single ``local_dev`` sandbox call.  The returned
        ``server_urls`` are then mapped back to the *original* task server
        names so that downstream consumers see the keys they expect.
        """
        if server_extra_params is None:
            server_extra_params = {}
        overrides = {}

        # Partition requested servers into local_dev vs. others
        local_dev_requested = [n for n in server_names if n in LOCAL_DEV_SERVER_NAMES]
        other_servers = [n for n in server_names if n not in LOCAL_DEV_SERVER_NAMES]

        # Acquire a single local_dev sandbox for all local_dev-mapped servers
        if local_dev_requested:
            result = self.acquire("local_dev")
            if result and result.get("server_urls"):
                api_urls: Dict[str, str] = result["server_urls"]
                # Map each task server name to its corresponding remote name in the response
                for task_name in local_dev_requested:
                    remote_name = LOCAL_DEV_TASK_TO_REMOTE_NAME.get(task_name, task_name)
                    if remote_name in api_urls:
                        overrides[task_name] = api_urls[remote_name]
                        print(f"[Klavis] Acquired sandbox for '{task_name}' (via local_dev, remote '{remote_name}'): {api_urls[remote_name]}")
                    else:
                        print(f"[Klavis] Warning: local_dev sandbox has no URL for remote name '{remote_name}' (task '{task_name}')")

        # Acquire individual sandboxes for non-local_dev servers
        for name in other_servers:
            sandbox_name = TASK_SERVER_TO_SANDBOX_NAME.get(name, name)
            result = self.acquire(sandbox_name, extra_params=server_extra_params.get(name))
            if result and result.get("server_urls"):
                for sname, surl in result["server_urls"].items():  # ideally only 1 server for non-local_dev
                    key = name if sname == sandbox_name else sname
                    overrides[key] = surl
                    print(f"[Klavis] Acquired sandbox for '{key}': {surl}")
        return overrides

    def get_sandbox_details(self, server_name: str, sandbox_id: str) -> Optional[Dict]:
        """Get detailed information about a specific sandbox instance."""
        url = f"{KLAVIS_API_BASE}/sandbox/{server_name}/{sandbox_id}"
        headers = {"Authorization": f"Bearer {self.api_key}"}
        try:
            resp = httpx.get(url, headers=headers, timeout=30)
            resp.raise_for_status()
            return resp.json()
        except Exception as e:
            print(f"[Klavis] Failed to get sandbox details for '{sandbox_id}': {e}")
            return None

    def release_all(self):
        """Release all acquired sandboxes."""
        headers = {"Authorization": f"Bearer {self.api_key}"}
        for sandbox in self.acquired_sandboxes:
            sandbox_id = sandbox.get("sandbox_id")
            server_name = sandbox.get("server_name")
            if not sandbox_id or not server_name:
                continue
            try:
                resp = httpx.delete(
                    f"{KLAVIS_API_BASE}/sandbox/{server_name}/{sandbox_id}",
                    headers=headers, timeout=30,
                )
                resp.raise_for_status()
                print(f"[Klavis] Released sandbox '{sandbox_id}' for '{server_name}'")
            except Exception as e:
                print(f"[Klavis] Failed to release sandbox '{sandbox_id}': {e}")
        self.acquired_sandboxes.clear()
