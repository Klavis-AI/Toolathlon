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

    def acquire(self, server_name: str) -> Optional[Dict]:
        """Acquire a sandbox for a given MCP server.
        
        Returns response dict with sandbox_id, server_urls, etc. or None on failure.
        """
        url = f"{KLAVIS_API_BASE}/sandbox/{server_name}"
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
        }
        try:
            resp = httpx.post(url, json={"benchmark": "Toolathlon"}, headers=headers, timeout=60)
            resp.raise_for_status()
            data = resp.json()
            self.acquired_sandboxes.append(data)
            return data
        except Exception as e:
            print(f"[Klavis] Failed to acquire sandbox for '{server_name}': {e}")
            return None

    def acquire_for_servers(self, server_names: List[str]) -> Dict[str, str]:
        """Acquire sandboxes for multiple servers.
        
        Returns a dict mapping server_name -> streamable-http URL for servers
        that were successfully acquired. Servers that fail are silently skipped.
        """
        overrides = {}
        for name in server_names:
            result = self.acquire(name)
            if result and result.get("server_urls"):
                for sname, surl in result["server_urls"].items(): # local_dev sandbox might have multiple servers
                    overrides[sname] = surl
                    print(f"[Klavis] Acquired sandbox for '{sname}': {surl}")
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
