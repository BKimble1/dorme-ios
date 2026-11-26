"""Wi-Fi setup over Bluetooth, sealed with the on-screen code (2026-11-25).

The phone never sends a Wi-Fi password in the clear over BLE:
  1. The robot shows a one-time 6-digit code AND a QR code on its screen. The QR holds
        DORME1:<6 digits>:<robot X25519 public key, base64url>:<128-bit token, base64url>
     (qr_payload()). Key and token are fresh for every code and never leave the robot by radio.
  2. The phone scans the QR, makes its own X25519 key, derives
        key = HKDF-SHA256(shared secret, salt = the 16-byte token, info = "dorme-wifi-v1", 32 bytes)
     and seals {"ssid", "psk"} or {"ssid", "eap": {...}} with AES-256-GCM (12-byte nonce, aad "dorme-wifi-v1").
  3. It writes  phone_public(32) | nonce(12) | ciphertext+tag  to the BLE wifi characteristic.
  4. open_sealed() decrypts. A failed tag counts towards the pairing lockout. Success uses the code up.

Because the robot's public key and the 128-bit token reach the phone optically (the QR), a relay on the
BLE link cannot sit in the middle and there is nothing short enough to brute-force. (An earlier draft salted
with the 6 digits; research showed an active relay could then try all 10^6 codes offline.)
"""
import base64
import json
import os
import time

AAD = b"dorme-wifi-v1"
BLE_INFO = b"dorme-ble-v2"
BLE_WIFI_AAD = b"dorme-wifi-v2"
BLE_SESSION_S = 15 * 60


class Provisioner:
    def __init__(self, auth):
        self.auth = auth
        self._for_code = None
        self._priv = None
        self._token = None

    def _ensure_key(self):
        from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
        code = self.auth.active_code()
        if code is None:
            self._for_code, self._priv, self._token = None, None, None
            return None
        if self._for_code != code:
            self._for_code, self._priv, self._token = code, X25519PrivateKey.generate(), os.urandom(16)
        return code

    def qr_payload(self):
        """The text the robot's screen encodes as a QR code while a code is live, else None."""
        pub = self.robot_public()
        if pub is None:
            return None
        b64 = lambda b: base64.urlsafe_b64encode(b).decode().rstrip("=")
        return f"DORME1:{self._for_code}:{b64(pub)}:{b64(self._token)}"

    def robot_public(self):
        """32 raw bytes while a code is live, else None."""
        from cryptography.hazmat.primitives import serialization
        if self._ensure_key() is None:
            return None
        return self._priv.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)

    # ---------------- 2026-11-26: Bluetooth pairing without a QR or code ----------------
    # The phone writes its X25519 public key over BLE. While pairing is open (BleWindow in http_server), the
    # robot answers with its own fresh public key and a sealed "welcome": a bearer token plus every address the
    # phone can use to reach it (Wi-Fi, Tailscale, the robot's own hotspot).
    #   key = HKDF-SHA256(shared, salt = phone_pub | robot_pub, info "dorme-ble-v2")
    # The same key later seals the Wi-Fi password the phone sends (aad "dorme-wifi-v2").
    # Trust model: whoever is in Bluetooth range while pairing is open (trust on first use). There is no
    # out-of-band check, so a relay attacker in range during that window could pair too; the window, the
    # on-screen notice "Paired: <name>" and the paired-phones list in the app are the mitigations.
    def ble_hello(self, phone_pub, welcome):
        """-> robot_pub(32) | nonce(12) | AES-GCM(welcome JSON)."""
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        from cryptography.hazmat.primitives.kdf.hkdf import HKDF
        if not isinstance(phone_pub, (bytes, bytearray)) or len(phone_pub) != 32:
            raise ValueError("phone key must be 32 bytes")
        priv = X25519PrivateKey.generate()
        robot_pub = priv.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        shared = priv.exchange(X25519PublicKey.from_public_bytes(bytes(phone_pub)))
        key = HKDF(algorithm=hashes.SHA256(), length=32, salt=bytes(phone_pub) + robot_pub,
                   info=BLE_INFO).derive(shared)
        now = time.monotonic()
        sessions = {k: v for k, v in getattr(self, "sessions", {}).items() if v[1] > now}
        while len(sessions) >= 4:
            sessions.pop(min(sessions, key=lambda k: sessions[k][1]))
        sessions[bytes(phone_pub)] = (key, now + BLE_SESSION_S)
        self.sessions = sessions
        nonce = os.urandom(12)
        body = json.dumps(welcome, separators=(",", ":")).encode()
        return robot_pub + nonce + AESGCM(key).encrypt(nonce, body, BLE_INFO)

    def _ble_session_key(self, phone_pub):
        entry = getattr(self, "sessions", {}).get(bytes(phone_pub))
        if entry and entry[1] > time.monotonic():
            return entry[0]
        return None

    def open_sealed(self, blob):
        """-> (credentials dict, None) or (None, error code)."""
        from cryptography.exceptions import InvalidTag
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PublicKey
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        from cryptography.hazmat.primitives.kdf.hkdf import HKDF
        now = self.auth.clock()
        if now < self.auth.locked_until:
            return None, "LOCKED_OUT"
        if isinstance(blob, (bytes, bytearray)) and 60 <= len(blob) <= 600:
            key = self._ble_session_key(blob[:32])
            if key is not None:                     # sealed with a Bluetooth pairing session
                try:
                    creds = json.loads(AESGCM(key).decrypt(bytes(blob[32:44]), bytes(blob[44:]), BLE_WIFI_AAD))
                except (InvalidTag, ValueError):
                    self.auth.note_failure(now)
                    return None, "BAD_PIN"
                if not isinstance(creds, dict) or not isinstance(creds.get("ssid"), str):
                    return None, "BAD_REQUEST"
                return creds, None
        code = self._ensure_key()
        if code is None:
            return None, "NO_CODE"
        if not isinstance(blob, (bytes, bytearray)) or len(blob) < 32 + 12 + 16 + 2 or len(blob) > 600:
            return None, "BAD_REQUEST"
        try:
            shared = self._priv.exchange(X25519PublicKey.from_public_bytes(bytes(blob[:32])))
            key = HKDF(algorithm=hashes.SHA256(), length=32, salt=self._token, info=AAD).derive(shared)
            plain = AESGCM(key).decrypt(bytes(blob[32:44]), bytes(blob[44:]), AAD)
            creds = json.loads(plain)
        except (InvalidTag, ValueError):
            self.auth.note_failure(now)
            return None, "BAD_PIN"
        if not isinstance(creds, dict) or not isinstance(creds.get("ssid"), str):
            return None, "BAD_REQUEST"
        self.auth.cancel_code()
        self._for_code, self._priv, self._token = None, None, None
        return creds, None


def parse_qr(text):
    """-> (code, robot_pub bytes, token bytes) from a DORME1 QR payload (what the phone does)."""
    tag, code, pub, token = text.split(":")
    if tag != "DORME1":
        raise ValueError("not a DORM-E code")
    unb64 = lambda s: base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
    return code, unb64(pub), unb64(token)


def seal_for_test(robot_pub, token, creds):
    """What the phone does (used by tests and the simulator)."""
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    priv = X25519PrivateKey.generate()
    shared = priv.exchange(X25519PublicKey.from_public_bytes(robot_pub))
    key = HKDF(algorithm=hashes.SHA256(), length=32, salt=token, info=AAD).derive(shared)
    nonce = os.urandom(12)
    pub = priv.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return pub + nonce + AESGCM(key).encrypt(nonce, json.dumps(creds).encode(), AAD)


def ble_phone_side(welcome_blob, phone_priv):
    """What the phone does with the robot's reply (tests and simulator): -> (welcome dict, key)."""
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PublicKey
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    robot_pub, nonce, sealed = welcome_blob[:32], welcome_blob[32:44], welcome_blob[44:]
    phone_pub = phone_priv.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    shared = phone_priv.exchange(X25519PublicKey.from_public_bytes(robot_pub))
    key = HKDF(algorithm=hashes.SHA256(), length=32, salt=phone_pub + robot_pub, info=BLE_INFO).derive(shared)
    return json.loads(AESGCM(key).decrypt(nonce, sealed, BLE_INFO)), key


def ble_seal_wifi(key, phone_pub, creds):
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    nonce = os.urandom(12)
    return phone_pub + nonce + AESGCM(key).encrypt(nonce, json.dumps(creds).encode(), BLE_WIFI_AAD)
