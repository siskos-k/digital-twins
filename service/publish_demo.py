"""Publish explicitly simulated readings to a registered device's exact topic."""
import argparse
import json
import random
import time
import paho.mqtt.client as mqtt

parser = argparse.ArgumentParser()
parser.add_argument("--host", default="127.0.0.1")
parser.add_argument("--port", type=int, default=1883)
parser.add_argument("--topic", required=True)
parser.add_argument("--count", type=int, default=20)
args = parser.parse_args()
client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
client.connect(args.host, args.port)
client.loop_start()
try:
    for _ in range(args.count):
        payload = dict(temperature=round(random.uniform(22, 25), 2), humidity=round(random.uniform(40, 55), 1), timestamp=time.time(), source="simulated")
        client.publish(args.topic, json.dumps(payload), qos=1).wait_for_publish(timeout=5)
        print(json.dumps(payload), flush=True)
        time.sleep(2)
finally:
    client.disconnect()
    client.loop_stop()
