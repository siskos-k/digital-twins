import json
import tempfile
import threading
import time
import unittest
import uuid
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from service.server import Database, make_server


def device(topic="room1/sensor1"):
    return dict(id=str(uuid.uuid4()).upper(), roomID=str(uuid.uuid4()).upper(), name="Sensor", kind="Temperature / humidity sensor", position=dict(x=0, y=1, z=0), topic=topic)


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.path = self.folder.name + "/test.sqlite"
        self.db = Database(self.path)
        self.device = self.db.register(device())

    def tearDown(self):
        self.db.connection.close()
        self.folder.cleanup()

    def test_persistence_routing_and_units(self):
        other = self.db.register(device("room2/sensor1"))
        self.assertEqual(self.db.ingest("room1/sensor1", b'{"temperature":23.5,"humidity":45,"source":"simulated"}'), 2)
        self.assertEqual(self.db.readings(other["id"]), [])
        reopened = Database(self.path)
        readings = reopened.readings(self.device["id"])
        self.assertEqual({r["unit"] for r in readings}, {"°C", "%"})
        self.assertTrue(all(r["source"] == "simulated" for r in readings))
        reopened.connection.close()

    def test_bad_payloads_are_atomic(self):
        for payload in (b'[]', b'{"temperature":"hot"}', b'{"temperature":NaN}', b'{"power":true}', b'{"timestamp":-1,"temperature":23}', b'{"source":"unknown","temperature":1}', b'{"temperature":23,"humidity":"bad"}'):
            with self.assertRaises(ValueError):
                self.db.ingest("room1/sensor1", payload)
        self.assertEqual(self.db.readings(self.device["id"]), [])

    def test_topic_change_and_delete(self):
        updated = dict(self.device, topic="room1/new")
        self.db.register(updated)
        self.assertEqual(self.db.topics(), {"room1/new"})
        self.assertEqual(self.db.ingest("room1/sensor1", b'{"temperature":20}'), 0)
        self.db.ingest("room1/new", b'{"temperature":21}')
        self.db.delete(self.device["id"])
        self.assertEqual(self.db.readings(self.device["id"]), [])
        self.assertEqual(self.db.topics(), set())

    def test_validation(self):
        for entry in (dict(self.device, topic="room/#"), dict(self.device, name=" "), dict(self.device, kind="unknown"), dict(self.device, position=dict(x=float("nan"), y=0, z=0))):
            with self.assertRaises(ValueError):
                self.db.register(entry)

    def test_http_auth_register_read_delete(self):
        class FakeCollector:
            connected = True
            last_error = None
            def refresh(self): pass
        server = make_server(self.db, FakeCollector(), "test-token", ("127.0.0.1", 0))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f"http://127.0.0.1:{server.server_port}"
        def call(path, method="GET", payload=None, token="test-token"):
            request = Request(base + path, data=json.dumps(payload).encode() if payload else None, method=method, headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
            with urlopen(request, timeout=5) as response:
                return json.load(response)
        try:
            with self.assertRaises(HTTPError) as error:
                call("/health", token="wrong")
            self.assertEqual(error.exception.code, 401)
            error.exception.close()
            self.assertTrue(call("/health")["mqttConnected"])
            new = device()
            self.assertTrue(call("/devices/" + new["id"], "PUT", new)["saved"])
            self.db.ingest(new["topic"], b'{"temperature":25}')
            values = call("/devices/" + new["id"] + "/readings")
            self.assertEqual(values[0]["value"], 25)
            self.assertEqual(values[0]["deviceID"], new["id"])
            self.assertTrue(call("/devices/" + new["id"], "DELETE")["deleted"])
            self.assertEqual(call("/devices/" + new["id"] + "/readings"), [])
        finally:
            server.shutdown(); server.server_close(); thread.join()

    def test_bounded_history(self):
        # Keep the newest readings when the demo exceeds its per-device bound.
        with self.db.lock, self.db.connection:
            self.db.connection.executemany("INSERT INTO readings VALUES(?,?,?,?)", [(str(i), self.device["id"], float(i + 1), "{}") for i in range(10005)])
        self.db.ingest(self.device["topic"], b'{"temperature":24}')
        count = self.db.connection.execute("SELECT COUNT(*) FROM readings").fetchone()[0]
        self.assertEqual(count, 10000)


if __name__ == "__main__": unittest.main()
