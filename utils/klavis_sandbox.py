"""Klavis MCP Sandbox API client."""

import os
import httpx
from typing import Dict, Optional, List


KLAVIS_API_BASE = "https://api.klavis.ai"


class KlavisSandbox:
    def __init__(self, api_key: str = None):
        self.api_key = api_key or os.environ.get("KLAVIS_API_KEY")
        if not self.api_key:
            raise ValueError("KLAVIS_API_KEY is required")
        self.acquired_sandboxes: List[Dict] = []

    @staticmethod
    def _task_dir_to_task_name(task_dir: str) -> str:
        """Convert task_dir like 'finalpool/notion-personal-website' to Klavis task_name."""
        task_name = task_dir.split("/")[-1].replace("-", "_")
        return f"Toolathlon_{task_name}"

    def acquire(self, server_name: str, task_dir: str) -> Optional[Dict]:
        """Acquire a sandbox for a given MCP server and task.
        
        Returns response dict with sandbox_id, server_urls, etc. or None on failure.
        """
        # task_name = self._task_dir_to_task_name(task_dir) 
        url = f"{KLAVIS_API_BASE}/sandbox/{server_name}"
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
        }
        try:
            resp = httpx.post(url, json={"benchmark": "MCP_Atlas"}, headers=headers, timeout=60) # TODO: change based on API change
            resp.raise_for_status()
            data = resp.json()
            self.acquired_sandboxes.append(data)
            return data
        except Exception as e:
            print(f"[Klavis] Failed to acquire sandbox for '{server_name}': {e}")
            return None

    def acquire_for_servers(self, server_names: List[str], task_dir: str) -> Dict[str, str]:
        """Acquire sandboxes for multiple servers.
        
        Returns a dict mapping server_name -> streamable-http URL for servers
        that were successfully acquired. Servers that fail are silently skipped.
        """
        overrides = {}
        for name in server_names:
            result = self.acquire(name, task_dir)
            if result and result.get("server_urls"):
                for sname, surl in result["server_urls"].items(): # local_dev sandbox might have multiple servers
                    overrides[sname] = surl
                    print(f"[Klavis] Acquired sandbox for '{sname}': {surl}")
        return overrides

    def release_all(self):
        """Release all acquired sandboxes."""
        headers = {"Authorization": f"Bearer {self.api_key}"}
        for sb in self.acquired_sandboxes:
            sandbox_id = sb.get("sandbox_id")
            server_name = sb.get("server_name")
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
