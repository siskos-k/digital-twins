"""Local MQTT -> SQLite collector and authenticated HTTP API for Digital Twins."""
import hmac
import json
import logging
import math
import os
import sqlite3
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

METRICS = {"temperature": "°C", "humidity": "%", "power": "W", "energy": "kWh", "co2": "ppm", "occupied": "", "on": "", "brightness": "%", "targetTemperature": "°C"}
KINDS = {"AC / heat pump", "Temperature / humidity sensor", "Energy meter", "Light", "Occupancy sensor", "Air quality sensor", "Door / window sensor", "Thermostat / radiator", "Other"}


class Database:
    def __init__(self, path):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.connection = sqlite3.connect(path, check_same_thread=False)
        self.connection.row_factory = sqlite3.Row
        self.lock = threading.RLock()
        with self.connection:
            self.connection.executescript("""
                PRAGMA journal_mode=WAL;
                PRAGMA foreign_keys=ON;
                CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY, topic TEXT NOT NULL, json TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS readings(id TEXT PRIMARY KEY, device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE, timestamp REAL NOT NULL, json TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS device_time ON readings(device_id, timestamp DESC);
            """)

    @staticmethod
    def validated(device):
        if not isinstance(device, dict):
            raise ValueError("Expected a device object")
        for field in ("id", "roomID"):
            device[field] = str(uuid.UUID(device[field])).upper()
        if not isinstance(device.get("name"), str) or not device["name"].strip():
            raise ValueError("Device name is required")
        if device.get("kind") not in KINDS:
            raise ValueError("Unknown equipment category")
        position = device["position"]
        if any(isinstance(position[k], bool) or not isinstance(position[k], (int, float)) or not math.isfinite(position[k]) for k in ("x", "y", "z")):
            raise ValueError("Invalid position")
        topic = device.get("topic", "")
        if not isinstance(topic, str):
            raise ValueError("MQTT topic must be a string")
        topic = topic.strip()
        if not isinstance(topic, str) or any(c in topic for c in "#+\0") or len(topic.encode()) > 512:
            raise ValueError("Use an exact MQTT topic, without wildcards (maximum 512 bytes)")
        device["topic"] = topic
        return device

    def register(self, device):
        device = self.validated(device)
        with self.lock, self.connection:
            self.connection.execute("INSERT INTO devices VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET topic=excluded.topic,json=excluded.json", (device["id"], device["topic"], json.dumps(device)))
        return device

    def delete(self, identifier):
        with self.lock, self.connection:
            self.connection.execute("DELETE FROM devices WHERE id=?", (identifier,))

    def topics(self):
        with self.lock:
            return {row[0] for row in self.connection.execute("SELECT DISTINCT topic FROM devices WHERE topic != ''")}

    def ingest(self, topic, payload):
        if len(payload) > 16384:
            raise ValueError("MQTT payload too large")
        message = json.loads(payload)
        if not isinstance(message, dict):
            raise ValueError("Expected a JSON object with supported metric names")
        stamp = message.get("timestamp", time.time())
        if isinstance(stamp, bool) or not isinstance(stamp, (int, float)) or not math.isfinite(stamp) or stamp <= 0 or stamp > time.time() + 300:
            raise ValueError("timestamp must be Unix seconds, no more than five minutes in the future")
        source = message.get("source", "mqtt")
        if source not in ("mqtt", "simulated"):
            raise ValueError("source must be mqtt or simulated")
        metrics = []
        for name, unit in METRICS.items():
            if name not in message:
                continue
            value = message[name]
            if isinstance(value, bool) and name in ("on", "occupied"):
                value = int(value)
            if isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value):
                raise ValueError(f"Invalid value for {name}")
            metrics.append((name, value, unit))
        if not metrics:
            raise ValueError("No supported metrics in payload")
        count = 0
        with self.lock, self.connection:
            devices = list(self.connection.execute("SELECT id FROM devices WHERE topic=?", (topic,)))
            for device in devices:
                for metric, value, unit in metrics:
                    reading = dict(id=str(uuid.uuid4()), deviceID=device["id"], metric=metric, value=value, unit=unit, timestamp=stamp, source=source)
                    self.connection.execute("INSERT INTO readings VALUES(?,?,?,?)", (reading["id"], device["id"], stamp, json.dumps(reading)))
                    count += 1
                # Bound the local demo's disk use to the latest 10,000 readings per device.
                self.connection.execute("DELETE FROM readings WHERE device_id=? AND id NOT IN (SELECT id FROM readings WHERE device_id=? ORDER BY timestamp DESC LIMIT 10000)", (device["id"], device["id"]))
        return count

    def readings(self, identifier, limit=500):
        with self.lock:
            return [json.loads(row[0]) for row in self.connection.execute("SELECT json FROM readings WHERE device_id=? ORDER BY timestamp DESC LIMIT ?", (identifier, limit))]


class Collector:
    def __init__(self, database, host, port):
        import paho.mqtt.client as mqtt
        self.database = database
        self.host, self.port = host, port
        self.connected = False
        self.last_error = None
        self._subscribed = set()
        self._lock = threading.RLock()
        self.client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="digital-twins-collector")
        if os.environ.get("MQTT_USERNAME"):
            self.client.username_pw_set(os.environ["MQTT_USERNAME"], os.environ.get("MQTT_PASSWORD"))
        if os.environ.get("MQTT_TLS") == "1":
            self.client.tls_set()
        self.client.reconnect_delay_set(min_delay=1, max_delay=30)
        self.client.on_connect = self.on_connect
        self.client.on_disconnect = self.on_disconnect
        self.client.on_message = self.on_message

    def start(self):
        self.client.connect_async(self.host, self.port, keepalive=30)
        self.client.loop_start()

    def stop(self):
        self.client.disconnect()
        self.client.loop_stop()

    def on_connect(self, client, userdata, flags, reason_code, properties):
        self.connected = reason_code == 0
        self.last_error = None if self.connected else str(reason_code)
        with self._lock:
            self._subscribed = set()
        self.refresh()

    def on_disconnect(self, client, userdata, flags, reason_code, properties):
        self.connected = False

    def refresh(self):
        with self._lock:
            if not self.connected:
                return
            topics = self.database.topics()
            for topic in topics - self._subscribed:
                self.client.subscribe(topic, qos=1)
            for topic in self._subscribed - topics:
                self.client.unsubscribe(topic)
            self._subscribed = topics

    def on_message(self, client, userdata, message):
        try:
            # Retained data without its own timestamp has unknown freshness: do not relabel it as current.
            if message.retain and "timestamp" not in json.loads(message.payload):
                raise ValueError("Retained readings require a timestamp")
            self.database.ingest(message.topic, message.payload)
            self.last_error = None
        except (ValueError, KeyError, TypeError, UnicodeError, sqlite3.Error) as error:
            self.last_error = str(error)
            logging.warning("Rejected MQTT payload: %s", error)


def make_server(database, collector, token, address=("127.0.0.1", 8080)):
    if not token:
        raise ValueError("Set DIGITAL_TWINS_API_TOKEN before starting the service")

    class Handler(BaseHTTPRequestHandler):
        def send_json(self, status, data):
            body = json.dumps(data, allow_nan=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def authorized(self):
            if not hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + token):
                self.send_json(401, {"error": "Invalid API token"})
                return False
            return True

        def do_GET(self):
            if not self.authorized():
                return
            parsed = urlparse(self.path)
            if parsed.path == "/health":
                self.send_json(200, {"mqttConnected": collector.connected, "lastError": collector.last_error})
                return
            parts = parsed.path.strip("/").split("/")
            try:
                if len(parts) == 3 and parts[0] == "devices" and parts[2] == "readings":
                    identifier = str(uuid.UUID(parts[1])).upper()
                    limit = max(1, min(int(parse_qs(parsed.query).get("limit", [500])[0]), 500))
                    self.send_json(200, database.readings(identifier, limit))
                    return
            except (ValueError, TypeError):
                self.send_json(400, {"error": "Invalid device ID or limit"})
                return
            self.send_json(404, {"error": "Not found"})

        def do_PUT(self):
            if not self.authorized():
                return
            parts = urlparse(self.path).path.strip("/").split("/")
            if len(parts) != 2 or parts[0] != "devices":
                self.send_json(404, {"error": "Not found"})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 16384:
                    raise ValueError("Device request must be 1–16384 bytes")
                device = json.loads(self.rfile.read(length))
                identifier = str(uuid.UUID(parts[1])).upper()
                if not isinstance(device, dict) or str(uuid.UUID(device["id"])).upper() != identifier:
                    raise ValueError("Device ID does not match URL")
                database.register(device)
                collector.refresh()
                self.send_json(200, {"saved": True})
            except (ValueError, KeyError, TypeError, AttributeError) as error:
                self.send_json(400, {"error": str(error)})

        def do_DELETE(self):
            if not self.authorized():
                return
            parts = urlparse(self.path).path.strip("/").split("/")
            try:
                if len(parts) != 2 or parts[0] != "devices":
                    raise ValueError("Invalid device URL")
                database.delete(str(uuid.UUID(parts[1])).upper())
                collector.refresh()
                self.send_json(200, {"deleted": True})
            except ValueError as error:
                self.send_json(400, {"error": str(error)})

    return ThreadingHTTPServer(address, Handler)


def main():
    logging.basicConfig(level=logging.INFO)
    database = Database(os.environ.get("DATABASE_PATH", "data/telemetry.sqlite"))
    collector = Collector(database, os.environ.get("MQTT_HOST", "127.0.0.1"), int(os.environ.get("MQTT_PORT", "1883")))
    server = make_server(database, collector, os.environ.get("DIGITAL_TWINS_API_TOKEN", ""), (os.environ.get("HTTP_HOST", "127.0.0.1"), int(os.environ.get("HTTP_PORT", "8080"))))
    collector.start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        collector.stop()


if __name__ == "__main__":
    main()
