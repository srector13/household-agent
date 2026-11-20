import asyncio
from types import SimpleNamespace

from app.mail import MailListener, html_to_text, parse_message, strip_quoted
from conftest import make_cfg

PLAIN = b"""From: Lincoln Elementary <office@school.example.org>
To: me@example.com
Subject: Early dismissal Wednesday
Message-ID: <abc123@school.example.org>
Date: Thu, 19 Nov 2026 10:00:00 -0600
Content-Type: text/plain; charset=utf-8

School will dismiss at 12:30 PM on Wednesday, November 25.

Thanks,
Office

--
Lincoln Elementary | 555-0100

On Wed, Nov 18, 2026 at 9:00 AM Someone <x@y.com> wrote:
> old stuff
"""

HTML = b"""From: office@school.example.org
Subject: Picture day
Content-Type: text/html; charset=utf-8

<html><head><style>p{color:red}</style></head><body><p>Picture day is <b>Monday</b>&nbsp;Nov 23.</p>
<div class="gmail_quote">On Tue someone wrote: <blockquote>ignore me</blockquote></div></body></html>
"""


def test_parse_plain_strips_signature_and_quote():
    m = parse_message(PLAIN, fallback_id="x")
    assert m["event_id"] == "mail:abc123@school.example.org"
    assert m["sender"] == "office@school.example.org"
    assert m["subject"] == "Early dismissal Wednesday"
    assert "12:30 PM" in m["text"] and "Lincoln Elementary |" not in m["text"] and "old stuff" not in m["text"]
    assert m["received_at"].utcoffset().total_seconds() == -6 * 3600


def test_parse_html():
    m = parse_message(HTML, fallback_id="INBOX:1:2")
    assert m["text"] == "Picture day is Monday Nov 23."
    assert m["event_id"].startswith("mail:") and len(m["event_id"]) > 10


def test_strip_outlook_and_iphone():
    t = "Can you sign the permission slip?\n\nSent from my iPhone\n\nFrom: Teacher\nSent: Monday\nblah"
    assert strip_quoted(t) == "Can you sign the permission slip?"
    t2 = "From: the PTA, a reminder about the bake sale Friday.\nBring cookies."
    assert "bake sale" in strip_quoted(t2)  # a From: line that is not a reply header is kept
    t3 = "Please reply by Friday.\n\n-----Original Message-----\nFrom: x"
    assert strip_quoted(t3) == "Please reply by Friday."


def test_html_to_text_skips_style_and_blockquote():
    assert html_to_text("<style>x</style><p>a</p><blockquote>b</blockquote><p>c</p>") == "a\n\nc"


class FakeIMAP:
    def __init__(self, messages):
        self.messages = messages  # uid -> (sender, raw)

    def search(self, crit):
        lo = int(crit[1].split(":")[0])
        uids = [u for u in self.messages if u >= lo]
        return uids or [max(self.messages)]  # IMAP "N:*" returns the last message when none match

    def fetch(self, uids, what):
        out = {}
        for u in uids:
            sender, raw = self.messages[u]
            mailbox, host = sender.split("@")
            env = SimpleNamespace(from_=[SimpleNamespace(mailbox=mailbox.encode(), host=host.encode())])
            out[u] = {b"ENVELOPE": env, b"BODY[]": raw}
        return out


def test_fetch_new_filters_senders_and_advances(tmp_path):
    cfg = make_cfg(tmp_path)
    submitted = []

    class P:
        async def ingest(self, ev):
            submitted.append(ev)
            return {"status": "accepted"}

    from app.models import DB
    db = DB(str(tmp_path / "x.db"))
    loop = asyncio.new_event_loop()
    import threading
    th = threading.Thread(target=loop.run_forever, daemon=True)
    th.start()
    try:
        health = SimpleNamespace(mail_status={})
        ml = MailListener(cfg, db, P(), health, loop)
        spam = PLAIN.replace(b"office@school.example.org", b"spam@evil.com")
        imap = FakeIMAP({5: ("office@school.example.org", PLAIN), 6: ("spam@evil.com", spam)})
        state = {"uidvalidity": 1, "last_uid": 4}
        ml._fetch_new(imap, "INBOX", "mail:INBOX", state)
        assert [e.sender_handle for e in submitted] == ["office@school.example.org"]
        assert submitted[0].subject == "Early dismissal Wednesday" and submitted[0].source == "mail"
        assert db.kv_get("mail:INBOX")["last_uid"] == 6
        ml._fetch_new(imap, "INBOX", "mail:INBOX", state)  # nothing new
        assert len(submitted) == 1
    finally:
        loop.call_soon_threadsafe(loop.stop)


def test_mail_event_through_pipeline(client, llm):
    from conftest import AUTH, event, extraction
    llm.responder = lambda p: extraction(event("Early dismissal", "2099-11-25T12:30"))
    m = parse_message(PLAIN, fallback_id="x")
    body = {"event_id": m["event_id"], "source": "mail", "sender_handle": m["sender"],
            "received_at": m["received_at"].isoformat(), "text": m["text"], "subject": m["subject"]}
    res = client.post("/api/events?sync=true", json=body, headers=AUTH).json()
    assert res["result"] == "queued"
    ev = client.get(f"/api/events/{m['event_id']}").json()
    assert ev["event"]["sender_label"] == "School"
    prompt = ev["trace"][3]["data"]["prompt"][1]["content"]
    assert "Subject: Early dismissal Wednesday" in prompt
    notes = ev["commands"][0]["payload"]["notes"]
    assert notes.startswith("From School (email “Early dismissal Wednesday”)")
    # non-allowlisted sender ignored
    body2 = {**body, "event_id": "mail:other", "sender_handle": "x@evil.com"}
    assert client.post("/api/events", json=body2, headers=AUTH).json()["status"] == "ignored"
