"""
Email domain utilities for multi-instance isolation.

When running multiple Toolathlon instances in parallel, each instance uses a 
separate email domain (e.g., mcp1.com, mcp2.com, ...) to avoid cross-instance
interference. The domain is controlled by the KLAVIS_EMAIL_DOMAIN env var.

Usage in evaluation/preprocess scripts:

    from utils.app_specific.poste.domain_utils import get_email_domain, rewrite_domain

    # Get current domain (defaults to "mcp.com" when env var is unset)
    domain = get_email_domain()

    # Build an email address with the correct domain
    email = f"alice@{domain}"

    # Rewrite all @mcp.com occurrences in a dict/list/string loaded from JSON
    data = rewrite_domain(json.load(f))
"""

import os
import json
from typing import Any

# ─── Default domain (matches the original single-instance setup) ────────────
DEFAULT_DOMAIN = "mcp.com"

# ─── Env var name ────────────────────────────────────────────────────────────
ENV_VAR = "KLAVIS_EMAIL_DOMAIN"


def get_email_domain() -> str:
    """Return the email domain for this instance.
    
    Reads from KLAVIS_EMAIL_DOMAIN env var; falls back to 'mcp.com'.
    """
    return os.environ.get(ENV_VAR, DEFAULT_DOMAIN)


def rewrite_domain(obj: Any, *, source: str = DEFAULT_DOMAIN, target: str = None) -> Any:
    """Recursively replace @{source} with @{target} in strings, dicts, and lists.
    
    If target is None, reads from get_email_domain().
    Returns a new object (does not mutate the original).
    
    Examples:
        >>> rewrite_domain("alice@mcp.com")           # → "alice@mcp2.com"
        >>> rewrite_domain({"email": "bob@mcp.com"})  # → {"email": "bob@mcp2.com"}
        >>> rewrite_domain(["x@mcp.com", 123])        # → ["x@mcp2.com", 123]
    """
    if target is None:
        target = get_email_domain()

    # No-op when domains match
    if source == target:
        return obj

    old = f"@{source}"
    new = f"@{target}"

    if isinstance(obj, str):
        return obj.replace(old, new)
    if isinstance(obj, dict):
        return {rewrite_domain(k, source=source, target=target): 
                rewrite_domain(v, source=source, target=target) 
                for k, v in obj.items()}
    if isinstance(obj, list):
        return [rewrite_domain(item, source=source, target=target) for item in obj]
    if isinstance(obj, tuple):
        return tuple(rewrite_domain(item, source=source, target=target) for item in obj)
    if isinstance(obj, set):
        return {rewrite_domain(item, source=source, target=target) for item in obj}
    # int, float, bool, None, etc. — pass through unchanged
    return obj


def load_and_rewrite_json(path: str) -> Any:
    """Load a JSON file and rewrite all @mcp.com addresses to the current domain.
    
    Convenience wrapper: json.load(f) + rewrite_domain(data).
    """
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    return rewrite_domain(data)


def rewrite_json_file_in_place(path: str) -> None:
    """Rewrite a JSON file on disk, replacing @mcp.com with the current domain.
    
    This is useful for config files read by external tools (e.g., emails-mcp)
    that don't go through our Python code.
    """
    domain = get_email_domain()
    if domain == DEFAULT_DOMAIN:
        return  # Nothing to rewrite

    with open(path, "r", encoding="utf-8") as f:
        content = f.read()

    new_content = content.replace(f"@{DEFAULT_DOMAIN}", f"@{domain}")
    if new_content != content:
        with open(path, "w", encoding="utf-8") as f:
            f.write(new_content)


def domain_str(local_part: str) -> str:
    """Build a full email address from a local part: domain_str('alice') → 'alice@mcp2.com'."""
    return f"{local_part}@{get_email_domain()}"
