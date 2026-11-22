"""Allowlist + rule-based prefilter. No LLM here."""
from __future__ import annotations

import fnmatch
import re
import unicodedata
from email.utils import parseaddr

from .config import Config
from .schemas import Event


def normalize_handle(handle: str | None) -> str:
    """Phone numbers → digits with leading +; emails → lowercase."""
    if not handle:
        return ""
    h = handle.strip()
    if "@" in h:
        return parseaddr(h)[1].lower() or h.lower()
    digits = re.sub(r"\D", "", h)
    if len(digits) == 10:  # US number without country code
        digits = "1" + digits
    return "+" + digits if digits else h


def allowlist_label(cfg: Config, ev: Event) -> tuple[bool, str | None]:
    """Return (allowed, label). Not-allowed events are dropped without being stored."""
    if ev.source == "mail":
        sender = normalize_handle(ev.sender_handle)
        mail = cfg.watch.mail
        for pat in mail.allow_senders:
            if fnmatch.fnmatch(sender, pat.lower()):
                label = next(
                    (lbl for p, lbl in mail.labels.items() if fnmatch.fnmatch(sender, p.lower())), None
                )
                return True, label or ev.sender_label or sender
        return False, None

    if ev.source == "manual":
        return True, ev.sender_label or "Manual"
    if ev.source == "capture":  # typed/dictated in the app: always mine
        return True, "Me"

    sender = normalize_handle(ev.sender_handle)
    for entry in cfg.watch.imessage.allow:
        if not entry.enabled:
            continue
        if entry.chat_id and ev.chat_id and entry.chat_id == ev.chat_id:
            return True, entry.label or ev.sender_label
        if entry.handle and normalize_handle(entry.handle) == sender:
            return True, entry.label or ev.sender_label
    return False, None


def self_chat(cfg: Config, ev: Event) -> bool:
    """Is this my notes-to-self conversation (an allowlist entry marked "this is me"), or a quick capture?"""
    if ev.source == "capture":
        return True
    if ev.source != "imessage":
        return False
    sender = normalize_handle(ev.sender_handle)
    for entry in cfg.watch.imessage.allow:
        if entry.enabled and entry.is_me and (
                (entry.chat_id and entry.chat_id == ev.chat_id)
                or (entry.handle and normalize_handle(entry.handle) == sender)):
            return True
    return False


# Cheap pre-filter for my own messages: only ones that sound like a commitment or a follow-up go to the LLM.
PROMISE_RE = re.compile(
    r"\b(i'?ll|i will|i'?m going to|i am going to|gonna|let me|i can|i promise|will do|on it|"
    r"get back to you|let you know|let me know|send (it|you|them)|tonight|tomorrow|this (morning|afternoon|evening|"
    r"weekend|week)|next week|by (mon|tue|wed|thu|fri|sat|sun)|(mon|tues|wednes|thurs|fri|satur|sun)day)\b", re.I)


def sounds_like_commitment(text: str) -> bool:
    return bool(PROMISE_RE.search(text or ""))


TAPBACK_RE = re.compile(
    r"^(Loved|Liked|Disliked|Laughed at|Emphasized|Questioned|Reacted .{1,8} to|"
    r"Removed an? .{1,20} from)\s+[“\"].*[”\"]\s*$",
    re.DOTALL,
)
FILLER = {
    "ok", "okay", "k", "kk", "lol", "lmao", "haha", "hahaha", "ha", "yes", "yep", "yeah", "ya",
    "no", "nope", "sure", "thanks", "thank you", "thx", "ty", "cool", "nice", "great", "sounds good",
    "love you", "ily", "omg", "same", "true", "right", "mhm", "np", "👍", "👌", "❤️", "😂",
}


def _is_emoji_only(text: str) -> bool:
    stripped = "".join(ch for ch in text if not ch.isspace())
    if not stripped:
        return True
    for ch in stripped:
        cat = unicodedata.category(ch)
        # So = symbol other (most emoji), Sk = modifiers, Mn/Me = variation selectors/keycaps,
        # Cf = ZWJ; anything else (letters, digits, punctuation) means real text.
        if cat not in ("So", "Sk", "Mn", "Me", "Cf") and ch not in "‍️":
            return False
    return True


def gate(cfg: Config, ev: Event) -> str | None:
    """Return a skip reason, or None if the event should go to the LLM."""
    text = (ev.text or "").strip()
    if ev.is_from_me and not cfg.watch.imessage.allow_self_notes and not self_chat(cfg, ev):
        return "from_me"
    if not text:
        return "empty"
    if TAPBACK_RE.match(text):
        return "tapback"
    if _is_emoji_only(text):
        return "emoji_only"
    if len(text) <= 3:
        return "too_short"
    norm = re.sub(r"[!.?,\s]+$", "", text.lower()).strip()
    if norm in FILLER:
        return "filler"
    return None
