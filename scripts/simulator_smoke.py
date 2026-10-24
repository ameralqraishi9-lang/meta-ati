#!/usr/bin/env python3
"""Install and launch the unsigned simulator app, then capture a review image."""
import json
import subprocess
import time
from pathlib import Path


def run(*args, timeout=180):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, timeout=timeout).strip()


payload = json.loads(run("xcrun", "simctl", "list", "devices", "available", "-j"))
devices = [device for runtime, group in payload["devices"].items() if ".iOS-" in runtime
           for device in group if device["name"].startswith("iPhone") and device.get("isAvailable")]
if not devices:
    raise SystemExit("No iPhone simulator runtime is available on this runner.")
device = next((d for d in devices if d["state"] == "Booted"), devices[0])
udid = device["udid"]
if device["state"] != "Booted":
    run("xcrun", "simctl", "boot", udid)
run("xcrun", "simctl", "bootstatus", udid, "-b", timeout=300)
app = "build-simulator/Build/Products/Debug-iphonesimulator/MetaStudy.app"
run("xcrun", "simctl", "install", udid, app)
print(run("xcrun", "simctl", "launch", udid, "com.metatistudy.MetaStudy"))
time.sleep(4)
Path("build").mkdir(exist_ok=True)
run("xcrun", "simctl", "io", udid, "screenshot", "build/MetaStudy-preview.png")
print("Simulator launch completed; review MetaStudy-preview.png for the initial UI.")
