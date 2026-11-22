"""PWA plumbing: manifest, service worker, offline page, icons, and HTTPS via a reverse proxy."""


def test_manifest_uses_app_name(client):
    m = client.get("/manifest.webmanifest")
    assert m.status_code == 200 and m.headers["content-type"].startswith("application/manifest+json")
    j = m.json()
    assert j["display"] == "standalone" and j["start_url"].startswith("/") and j["name"] == "Household Agent"
    assert {i["sizes"] for i in j["icons"]} == {"192x192", "512x512"}
    assert any(i.get("purpose") == "maskable" for i in j["icons"])
    client.patch("/api/settings", json={"dashboard": {"app_name": "Second Brain"}})
    j = client.get("/manifest.webmanifest").json()
    assert j["name"] == "Second Brain" and j["short_name"] == "Second Brain"
    assert '<meta name="apple-mobile-web-app-title" content="Second Brain">' in client.get("/").text


def test_service_worker(client):
    from app import __version__
    r = client.get("/sw.js")
    assert r.status_code == 200 and "javascript" in r.headers["content-type"]
    assert r.headers["service-worker-allowed"] == "/" and r.headers["cache-control"] == "no-cache"
    assert f'const VERSION = "{__version__}"' in r.text and "__VERSION__" not in r.text
    assert 'url.pathname.startsWith("/api/")' in r.text  # never caches the API / live stream


def test_offline_page_and_icons(client):
    assert "Can't reach the brain" in client.get("/offline").text
    for path in ["/static/icons/apple-touch-icon.png", "/static/icons/icon-192.png", "/static/icons/icon-512.png",
                 "/static/icons/icon-maskable-512.png", "/static/icons/favicon-32.png", "/static/icons/icon.svg"]:
        assert client.get(path).status_code == 200, path
    page = client.get("/").text
    assert 'rel="manifest"' in page and 'rel="apple-touch-icon"' in page and "viewport-fit=cover" in page


def test_writes_through_https_proxy(client):
    """`tailscale serve` terminates HTTPS and may rewrite Host — writes must still be allowed."""
    h = {"Origin": "https://brain.tail1234.ts.net", "Host": "127.0.0.1:8080", "X-Forwarded-Host": "brain.tail1234.ts.net"}
    assert client.patch("/api/settings", json={}, headers=h).status_code == 200
    client.patch("/api/settings", json={"dashboard": {"public_url": "https://brain.tail1234.ts.net"}})
    h2 = {"Origin": "https://brain.tail1234.ts.net", "Host": "127.0.0.1:8080"}
    assert client.patch("/api/settings", json={}, headers=h2).status_code == 200
    assert client.patch("/api/settings", json={}, headers={"Origin": "https://evil.example"}).status_code == 403


def test_back_button_and_nav_title(client, llm):
    from conftest import AUTH, msg
    client.post("/api/events?sync=true", json=msg(text="hello there friend"), headers=AUTH)
    t = client.get("/events/imessage:1").text
    assert 'class="nav-back" href="/activity"' in t and '<div class="nav-title">Wife</div>' in t
