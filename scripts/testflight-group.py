#!/usr/bin/env python3
"""Add a processed TestFlight build to an internal beta group.

App Store Connect has no `altool` command for group assignment. This uses the
same API key as the upload and the App Store Connect API:

  1. find the app record by bundle id,
  2. find the beta group by name (or the first internal group),
  3. poll until the build finishes processing (VALID),
  4. assign the build to the group.

Internal testers do not go through Beta App Review; only external groups do, so
this step is safe to automate for internal distribution. For an external group
the assignment submits the build for review and the wait is Apple's.

Requires the `cryptography` package (installed by the workflow).
"""

from __future__ import annotations

import argparse
import base64
import json
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

try:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
except ImportError:  # pragma: no cover - CI installs it explicitly
    sys.exit("install cryptography: python3 -m pip install cryptography")

API = "https://api.appstoreconnect.apple.com/v1"
TOKEN_LIFETIME = 15 * 60


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def make_token(key_path: str, key_id: str, issuer_id: str) -> str:
    with open(key_path, "rb") as handle:
        key = serialization.load_pem_private_key(handle.read(), password=None)
    now = int(time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {
        "iss": issuer_id,
        "iat": now,
        "exp": now + TOKEN_LIFETIME,
        "aud": "appstoreconnect-v1",
    }
    signing_input = (
        b64url(json.dumps(header, separators=(",", ":")).encode())
        + "."
        + b64url(json.dumps(payload, separators=(",", ":")).encode())
    )
    der = key.sign(signing_input.encode(), ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der)
    signature = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return signing_input + "." + b64url(signature)


def request(token: str, method: str, path: str, body: dict | None = None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        API + path,
        method=method,
        data=data,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            payload = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            payload = {"raw": raw.decode(errors="replace")}
        return error.code, payload


def find_app(token: str, bundle_id: str, platform: str | None) -> dict:
    status, body = request(
        token,
        "GET",
        f"/apps?filter[bundleId]={bundle_id}&limit=10",
    )
    if status != 200:
        raise SystemExit(f"could not list apps ({status}): {body}")
    apps = body.get("data", [])
    if platform:
        wanted = {
            "ios": {"IOS"},
            "macos": {"MACOS", "MAC_OS"},
        }[platform]
        apps = [
            app
            for app in apps
            if str(app.get("attributes", {}).get("platform", "")).upper() in wanted
        ]
    if not apps:
        raise SystemExit(f"no app record for {bundle_id} ({platform or 'any platform'})")
    return apps[0]


def find_group(token: str, app_id: str, name: str) -> dict:
    status, body = request(token, "GET", f"/betaGroups?filter[app]={app_id}&limit=200")
    if status != 200:
        raise SystemExit(f"could not list beta groups ({status}): {body}")
    groups = body.get("data", [])
    if not groups:
        raise SystemExit("the app has no TestFlight groups")
    for group in groups:
        if str(group.get("attributes", {}).get("name", "")).lower() == name.lower():
            return group
    if name.lower() == "internal":
        for group in groups:
            if group.get("attributes", {}).get("isInternalGroup") is True:
                return group
    available = ", ".join(
        f"{g.get('attributes', {}).get('name')}"
        f"{' (internal)' if g.get('attributes', {}).get('isInternalGroup') else ''}"
        for g in groups
    )
    raise SystemExit(f"no group named {name!r}; available: {available}")


def wait_for_build(
    token: str, app_id: str, build_number: str, timeout: int, poll: int
) -> dict:
    deadline = time.time() + timeout
    last_state = None
    while time.time() < deadline:
        status, body = request(
            token,
            "GET",
            f"/builds?filter[app]={app_id}&filter[version]={build_number}&limit=1",
        )
        if status == 200 and body.get("data"):
            build = body["data"][0]
            state = build.get("attributes", {}).get("processingState")
            if state != last_state:
                print(f"  build {build_number}: {state}")
                last_state = state
            if state == "VALID":
                return build
            if state in {"FAILED", "INVALID"}:
                raise SystemExit(f"build {build_number} processing failed: {state}")
        elif status not in (200, 404):
            raise SystemExit(f"could not poll builds ({status}): {body}")
        time.sleep(poll)
    raise SystemExit(
        f"build {build_number} was not VALID after {timeout}s; "
        "assign it in App Store Connect or re-run with a longer timeout"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--key-path", required=True)
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--issuer-id", required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--group", default="Internal")
    parser.add_argument("--platform", choices=["ios", "macos"], default="ios")
    parser.add_argument("--timeout", type=int, default=1800)
    parser.add_argument("--poll", type=int, default=30)
    args = parser.parse_args()

    token = make_token(args.key_path, args.key_id, args.issuer_id)
    app = find_app(token, args.bundle_id, args.platform)
    app_id = app["id"]
    group = find_group(token, app_id, args.group)
    group_id = group["id"]
    print(
        f"→ {args.bundle_id} build {args.build_number} → "
        f"{group.get('attributes', {}).get('name')}"
    )
    build = wait_for_build(token, app_id, args.build_number, args.timeout, args.poll)
    status, body = request(
        token,
        "POST",
        f"/betaGroups/{group_id}/relationships/builds",
        {"data": [{"type": "builds", "id": build["id"]}]},
    )
    if status in (200, 201, 204):
        print(f"Added build {args.build_number} to {args.group}.")
        return
    if status == 409:
        print(f"Build {args.build_number} is already in {args.group}.")
        return
    raise SystemExit(f"group assignment failed ({status}): {body}")


if __name__ == "__main__":
    main()
