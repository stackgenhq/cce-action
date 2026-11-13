import httpx
import requests

requests.get("https://example.com/health")
requests.post("https://example.com/submit", json={"ok": True})
httpx.get("https://example.com/modern")
