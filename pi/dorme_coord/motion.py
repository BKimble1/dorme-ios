"""Motion ownership: exactly one source may own movement at a time.

Rules (spec: API_V1.md "Movement ownership"):
- A client claims movement and receives a claim token. Holds must quote that token and an
  increasing sequence number. Each accepted hold keeps the lease alive for lease_ms.
- If holds stop arriving the lease expires and the coordinator stops the robot. No other message
  (heartbeat, state polling, pings) extends a lease.
- stop_all() is called by every stop. It bumps the epoch and drops the owner, so every claim
  issued before the stop is dead: after a stop the user must release and press again.
- Tasks own movement with lease_ms=None (no expiry) until they end or are cancelled.
- Nothing is persisted: a restart starts with no owner, so movement can never resume by itself.
"""
import secrets
import time


class MotionArbiter:
    def __init__(self, lease_ms=500, clock=None):
        self.lease_ms = lease_ms
        self.clock = clock or (lambda: int(time.monotonic() * 1000))
        self.owner = None
        self.epoch = 0

    def _alive(self, now):
        o = self.owner
        return o is not None and (o["lease_until"] is None or now <= o["lease_until"])

    def claim(self, source, client, lease_ms="default"):
        """-> (ok, code, claim_token)."""
        now = self.clock()
        if self._alive(now) and (self.owner["source"], self.owner["client"]) != (source, client):
            return False, "BUSY", None
        lease = self.lease_ms if lease_ms == "default" else lease_ms
        token = f"{self.epoch}-{secrets.token_hex(4)}"
        self.owner = {"source": source, "client": client, "claim": token, "since": now,
                      "lease_until": None if lease is None else now + lease, "seq": -1,
                      "direction": None}
        return True, None, token

    def hold(self, source, client, claim, direction, seq):
        """-> (ok, code, direction_changed)."""
        now = self.clock()
        o = self.owner
        if not self._alive(now):
            # An old token (from before a stop or after expiry) is STALE; no token at all is NOT_OWNER.
            return False, ("STALE" if claim else "NOT_OWNER"), False
        if (o["source"], o["client"]) != (source, client):
            return False, "BUSY", False
        if claim != o["claim"]:
            return False, "STALE", False
        if not isinstance(seq, int) or seq <= o["seq"]:
            return False, "STALE", False
        changed = direction != o["direction"]
        o["seq"], o["direction"] = seq, direction
        if o["lease_until"] is not None:
            o["lease_until"] = now + self.lease_ms
        return True, None, changed

    def release(self, source, client, claim=None):
        o = self.owner
        if o and (o["source"], o["client"]) == (source, client) and (claim is None or claim == o["claim"]):
            self.owner = None
            return True
        return False

    def stop_all(self):
        previous = self.owner
        self.owner = None
        self.epoch += 1
        return previous

    def expire(self):
        """Drop and return an owner whose lease ran out (the caller must stop the robot)."""
        now = self.clock()
        if self.owner is not None and not self._alive(now):
            expired, self.owner = self.owner, None
            return expired
        return None

    def view(self):
        o = self.owner
        if not o:
            return None
        return {"source": o["source"], "client": o["client"], "direction": o["direction"]}
