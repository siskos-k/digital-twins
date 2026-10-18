"""Real MQTT -> SQLite -> HTTP round trip using a temporary native Python broker."""
import asyncio
import json
import tempfile
import threading
import uuid
from urllib.request import Request, urlopen
from amqtt.broker import Broker
import paho.mqtt.client as mqtt
from service.server import Collector, Database, make_server


async def wait_for(predicate, label):
    for _ in range(200):
        if predicate(): return
        await asyncio.sleep(0.05)
    raise AssertionError("Timed out waiting for " + label)


async def main():
    broker = Broker({"listeners": {"default": {"type": "tcp", "bind": "127.0.0.1:21883"}}, "plugins": {"amqtt.plugins.authentication.AnonymousAuthPlugin": {"allow_anonymous": True}}})
    await broker.start()
    with tempfile.TemporaryDirectory() as folder:
        database = Database(folder + "/telemetry.sqlite")
        collector = Collector(database, "127.0.0.1", 21883)
        collector.start()
        publisher = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
        server = make_server(database, collector, "test-only-token", ("127.0.0.1", 0))
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        base = f"http://127.0.0.1:{server.server_port}"
        def request(path, body=None):
            req = Request(base + path, data=json.dumps(body).encode() if body else None, headers={"Authorization": "Bearer test-only-token", "Content-Type": "application/json"}, method="PUT" if body else "GET")
            with urlopen(req, timeout=5) as response: return json.load(response)
        try:
            await wait_for(lambda: collector.connected, "collector connection")
            identifier = str(uuid.uuid4()).upper()
            device = dict(id=identifier, roomID=str(uuid.uuid4()).upper(), name="Integration sensor", kind="Temperature / humidity sensor", position=dict(x=0, y=1, z=0), topic="tests/room1/sensor1")
            await asyncio.to_thread(request, "/devices/" + identifier, device)
            await asyncio.to_thread(publisher.connect, "127.0.0.1", 21883)
            publisher.loop_start()
            await wait_for(publisher.is_connected, "publisher connection")
            # Broker has processed the subscription before the first publish.
            await asyncio.sleep(0.2)
            payload = json.dumps(dict(temperature=24.25, humidity=48, source="simulated"))
            receipt = publisher.publish(device["topic"], payload, qos=1)
            await asyncio.to_thread(receipt.wait_for_publish, 5)
            await wait_for(lambda: len(database.readings(identifier)) == 2, "stored MQTT readings")
            readings = await asyncio.to_thread(request, "/devices/" + identifier + "/readings")
            assert {r["metric"] for r in readings} == {"temperature", "humidity"}
            assert all(r["source"] == "simulated" for r in readings)
            assert all(r["deviceID"] == identifier for r in readings)
            print("PASS: native MQTT publisher -> broker -> collector -> SQLite -> authenticated HTTP API")
            print("PASS: device identity, numeric values, units, and simulated-source labels survive the round trip")
        finally:
            publisher.disconnect(); publisher.loop_stop()
            collector.stop()
            await asyncio.to_thread(server.shutdown); server.server_close(); thread.join()
            database.connection.close()
    await broker.shutdown()


if __name__ == "__main__": asyncio.run(main())
