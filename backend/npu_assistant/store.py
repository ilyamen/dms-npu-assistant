"""Chat history in SQLite."""
import json
import sqlite3
import threading
import time
import uuid

SCHEMA = """
CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, title TEXT, created REAL, updated REAL);
CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session TEXT, role TEXT,
    content TEXT, device TEXT, created REAL);
CREATE INDEX IF NOT EXISTS messages_session ON messages(session, id);
"""


class Store:
    def __init__(self, path):
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.executescript(SCHEMA)
        if "stats" not in [r[1] for r in self.db.execute("PRAGMA table_info(messages)")]:
            self.db.execute("ALTER TABLE messages ADD COLUMN stats TEXT")
        self.lock = threading.Lock()

    def _q(self, sql, args=()):
        with self.lock, self.db:
            return [dict(r) for r in self.db.execute(sql, args)]

    def create(self, title):
        sid = uuid.uuid4().hex[:12]
        now = time.time()
        self._q("INSERT INTO sessions VALUES (?,?,?,?)", (sid, title[:80], now, now))
        return sid

    def exists(self, sid):
        return bool(self._q("SELECT 1 FROM sessions WHERE id=?", (sid,)))

    def add(self, sid, role, content, device=None, stats=None):
        now = time.time()
        self._q("INSERT INTO messages (session, role, content, device, created, stats) VALUES (?,?,?,?,?,?)",
                (sid, role, content, device, now, json.dumps(stats) if stats else None))
        self._q("UPDATE sessions SET updated=? WHERE id=?", (now, sid))

    def messages(self, sid):
        rows = self._q("SELECT role, content, device, created, stats FROM messages WHERE session=? ORDER BY id", (sid,))
        for r in rows:
            r["stats"] = json.loads(r["stats"]) if r["stats"] else None
        return rows

    def sessions(self, limit=100):
        return self._q("SELECT s.id, s.title, s.updated, COUNT(m.id) AS n FROM sessions s "
                       "LEFT JOIN messages m ON m.session=s.id GROUP BY s.id ORDER BY s.updated DESC LIMIT ?",
                       (limit,))

    def delete(self, sid):
        self._q("DELETE FROM messages WHERE session=?", (sid,))
        self._q("DELETE FROM sessions WHERE id=?", (sid,))
