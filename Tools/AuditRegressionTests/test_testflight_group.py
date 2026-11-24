#!/usr/bin/env python3
"""Offline regression for App Store Connect build lookup.

The API double models `Build.Attributes.version` as the uploaded build number,
so `filter[version]` selects that build number. The marketing version belongs to
the related prerelease version and is not part of this lookup.
"""

from __future__ import annotations

import importlib.util
import sys
import types
import unittest
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[2]


def load_script():
    # The production script imports cryptography only for JWT creation. These
    # stubs let this offline test exercise its HTTP lookup logic without the
    # package or a key.
    modules = {
        name: types.ModuleType(name)
        for name in [
            "cryptography",
            "cryptography.hazmat",
            "cryptography.hazmat.primitives",
            "cryptography.hazmat.primitives.asymmetric",
            "cryptography.hazmat.primitives.asymmetric.utils",
        ]
    }
    modules["cryptography.hazmat.primitives"].hashes = object()
    modules["cryptography.hazmat.primitives"].serialization = object()
    modules["cryptography.hazmat.primitives.asymmetric"].ec = object()
    modules["cryptography.hazmat.primitives.asymmetric.utils"].decode_dss_signature = object()
    sys.modules.update(modules)

    spec = importlib.util.spec_from_file_location(
        "backu_testflight_group", ROOT / "scripts/testflight-group.py"
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class TestFlightBuildLookupTests(unittest.TestCase):
    def test_polling_refreshes_jwt_after_fifteen_minutes(self) -> None:
        module = load_script()
        clock = [0.0]
        module.time = types.SimpleNamespace(time=lambda: clock[0], sleep=lambda seconds: clock.__setitem__(0, clock[0] + seconds))
        arguments = [
            "testflight-group.py",
            "--key-path",
            "unused.p8",
            "--key-id",
            "KEYID12345",
            "--issuer-id",
            "00000000-0000-0000-0000-000000000000",
            "--bundle-id",
            "me.otbeaumont.backu",
            "--build-number",
            "42",
            "--group",
            "External",
            "--timeout",
            "1200",
            "--poll",
            "60",
        ]
        issued: dict[str, float] = {}

        def make_token(key_path, key_id, issuer_id):
            token = f"token-{len(issued)}"
            issued[token] = clock[0]
            return token

        module.make_token = make_token
        assignments = []

        def request(token, method, path, body=None):
            if path.startswith("/apps?"):
                return 200, {"data": [{"id": "app-id", "attributes": {"name": "Backu"}}]}
            if path.startswith("/betaGroups?"):
                return 200, {"data": [{"id": "group-id", "attributes": {"name": "External", "isInternalGroup": False}}]}
            if path.startswith("/builds?"):
                query = parse_qs(urlsplit(path).query)
                if query.get("filter[version]") != ["42"]:
                    return 404, {}
                if clock[0] >= issued[token] + module.TOKEN_LIFETIME:
                    return 401, {"errors": [{"status": "401"}]}
                if clock[0] >= 16 * 60:
                    return 200, {"data": [{"id": "build-id", "attributes": {"processingState": "VALID", "version": "42"}}]}
                return 200, {"data": []}
            if method == "POST":
                assignments.append((path, body))
                return 204, {}
            return 404, {}

        module.request = request
        previous_argv = sys.argv
        sys.argv = arguments
        try:
            module.main()
        finally:
            sys.argv = previous_argv
        self.assertEqual(len(assignments), 1, "the processed build was not assigned before the JWT expired")

    def test_build_number_filters_uploaded_build_version(self) -> None:
        module = load_script()
        build_number = "20261124010203"
        build = {
            "id": "build-id",
            "attributes": {
                "processingState": "VALID",
                "version": build_number,
            },
        }
        paths: list[str] = []
        clock = [0.0]
        module.time = types.SimpleNamespace(time=lambda: clock[0], sleep=lambda _: None)

        def request(token, method, path, body=None):
            paths.append(path)
            clock[0] += 2
            query = parse_qs(urlsplit(path).query)
            if (
                query.get("filter[app]") == ["app-id"]
                and query.get("filter[version]") == [build_number]
            ):
                return 200, {"data": [build]}
            return 404, {}

        module.request = request
        found = module.wait_for_build(
            "token", "app-id", build_number, timeout=1, poll=0
        )
        self.assertEqual(found, build)
        self.assertEqual(
            paths,
            [f"/builds?filter[app]=app-id&filter[version]={build_number}&limit=1"],
        )
        self.assertNotIn("computedBuildVersion", build["attributes"])


if __name__ == "__main__":
    unittest.main()
