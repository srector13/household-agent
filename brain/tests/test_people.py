"""People tab: contact photos from the Mac, roster, person pages."""
import base64
import re

from conftest import AUTH, extraction, msg, reminder
from test_items import act, day, items, post, run_mac

J = {"X-Requested-With": "fetch"}
JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 200 + b"\xff\xd9"


def test_avatars_and_photos_everywhere(client, llm):
    r = client.post("/api/agent/avatars", headers=AUTH, json={"people": [
        {"handle": "+17855550000", "name": "Sarah Smith", "image": base64.b64encode(JPEG).decode(), "image_hash": "abc123"},
        {"handle": "+15550001111", "name": None, "image": base64.b64encode(b"not a jpeg").decode()},
    ]}).json()
    assert r == {"ok": True, "stored": 2}
    roster = client.app_state.db.all("SELECT handle, name, image IS NOT NULL AS img FROM avatars ORDER BY handle")
    assert [(x["handle"], x["img"]) for x in roster] == [("+15550001111", 0), ("+17855550000", 1)]
    page = client.get("/people").text
    assert 'class="avatar photo' in page and "Sarah Smith" in page
    src = re.search(r'src="(/avatars/[0-9a-f]+\.jpg[^"]*)"', page).group(1)
    img = client.get(src)
    assert img.status_code == 200 and img.headers["content-type"] == "image/jpeg" and img.content == JPEG
    # the photo shows up on activity rows too
    llm.responder = lambda p: extraction(reminder("Pick up eggs"))
    post(client, text="grab eggs?")
    assert 'class="avatar photo' in client.get("/activity").text
    assert client.post("/api/agent/avatars", json={"people": []}).status_code == 401


def test_person_page_sections(client, llm):
    llm.responder = lambda p: extraction(act("track_promise", title="Send Wife the photos", due_date=day(1)))
    post(client, event_id="imessage:1", text="I'll send you the photos tomorrow", is_from_me=True)
    llm.responder = lambda p: extraction(act("waiting_on", title="Babysitter answer", due_date=day(2)))
    post(client, event_id="imessage:2", text="I'll ask the babysitter and let you know")
    llm.responder = lambda p: extraction(act("save_to_collection", collection="gift_ideas", title="Kindle",
                                             url="https://example.com/k"),
                                         act("save_to_collection", collection="about_person", title="Ring size 6"))
    post(client, event_id="imessage:3", text="I'd love a kindle! also my ring size is 6")
    llm.responder = lambda p: extraction(act("save_to_collection", collection="gift_ideas", title="Bread maker",
                                             person="Mom"))
    post(client, event_id="imessage:4", text="Mom wants a bread maker")
    run_mac(client)
    page = client.get("/people").text
    assert "Wife" in page and "🤝 1" in page and "⏳ 1" in page and "🎁 1" in page
    assert "Also mentioned" in page and "Mom" in page
    key = page.split('href="/people/')[1].split('"')[0]
    t = client.get(f"/people/{key}").text
    for s in ("You promised Wife", "Send Wife the photos", "Waiting on Wife", "Babysitter answer", "Gift ideas",
              "Kindle", "Things to remember", "Ring size 6", "Recent messages", "I&#39;d love a kindle"):
        assert s in t, s
    assert 'href="https://example.com/k"' in t and 'class="nav-back" href="/people"' in t
    mom = [k for k in page.split('href="/people/')[1:] if "Mom" in k.split("</a>")[0]][0].split('"')[0]
    assert "Bread maker" in client.get(f"/people/{mom}").text
    assert client.get("/people/nope").status_code == 404


def test_people_tab_in_nav(client):
    t = client.get("/").text
    assert 'href="/people"' in t and ">People" in t
