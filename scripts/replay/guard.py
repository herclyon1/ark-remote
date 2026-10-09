"""Safety guard: the app under test must never talk to the real mailbox.

The real mailbox name (ARK_PHONE_TOPIC) is read at run time from the key table (default ~/.config/ark/密钥总表.md,
falling back to ~/.config/ark/push.env) and kept only as SHA-256 digests; it is never printed, logged or written.
Every topic the runner publishes to, and the topic stored in the app on the device, is compared against those digests.
This repository is public: no topic name and no digest of the real topic may ever be committed.
"""
import hashlib
import os
import re

DEFAULT_KEY_FILES = ["~/.config/ark/密钥总表.md", "~/.config/ark/push.env"]


class GuardError(RuntimeError):
    pass


def _digests(topic):
    t = topic.strip()
    return {hashlib.sha256(t.encode()).hexdigest(), hashlib.sha256(t.lower().encode()).hexdigest()}


def _read_real_topics(paths):
    found = []
    for p in paths:
        p = os.path.expanduser(p)
        if not os.path.exists(p):
            continue
        txt = open(p, encoding="utf-8", errors="replace").read()
        # markdown table row: | ARK_PHONE_TOPIC | ... | `value` | ...
        for m in re.finditer(r"^\|\s*ARK_PHONE_TOPIC\s*\|[^\n`]*`([^`]+)`", txt, re.M):
            found.append(m.group(1))
        # env file: ARK_PHONE_TOPIC=value
        for m in re.finditer(r"^\s*(?:export\s+)?ARK_PHONE_TOPIC\s*=\s*['\"]?([^'\"\s#]+)", txt, re.M):
            found.append(m.group(1))
    return found


class Guard:
    def __init__(self, throwaway_topic, key_files=None):
        self.key_files = key_files or DEFAULT_KEY_FILES
        topics = _read_real_topics(self.key_files)
        if not topics:
            raise GuardError("could not read the real mailbox name (ARK_PHONE_TOPIC) from the key files; "
                             "refusing to run without the guard (pass --key-file)")
        self.real = set()
        for t in topics:
            self.real |= _digests(t)
        self.topic = throwaway_topic.strip()
        if not self.topic:
            raise GuardError("--topic is empty")
        if self.is_real(self.topic):
            raise GuardError("--topic is the REAL mailbox; use a throwaway topic")
        self.real_count = len(topics)

    def is_real(self, topic):
        return bool(topic) and bool(_digests(topic) & self.real)

    def check_publish(self, topic):
        """Called before every POST to ntfy: only the throwaway topic (and its -hb twin) may be written."""
        if self.is_real(topic) or self.is_real(topic[:-3] if topic.endswith("-hb") else topic):
            raise GuardError("refusing to publish to the real mailbox")
        if topic not in (self.topic, self.topic + "-hb"):
            raise GuardError("refusing to publish to a topic other than --topic")

    def check_app_topic(self, stored):
        """stored = the topic in the app's saved config (None / '' when none). Raises when it is the real one."""
        if stored and self.is_real(stored):
            raise GuardError("the app on this device is configured for the REAL mailbox; launching it would talk to the "
                             "real machine. Clear its data yourself (back it up first) and rerun.")

    def real_topic_for_read(self):
        """The real topic is needed once, to compute the COS read-only state URL. Returned only to mailbox.fetch_real_state."""
        topics = _read_real_topics(self.key_files)
        return topics[0] if topics else None
