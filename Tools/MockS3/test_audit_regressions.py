#!/usr/bin/env python3
"""Focused regressions found while auditing Backu's S3 client and mock."""

from __future__ import annotations

import hashlib
import hmac
import http.client
import queue
import shutil
import tempfile
import threading
import unittest
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from urllib.parse import quote

import mock_s3
from test_mock_s3 import AKID, BUCKET, REGION, SECRET, encode_path, encode_query

XMLNS = "http://s3.amazonaws.com/doc/2006-03-01/"
NS = {"s3": XMLNS}


def _hmac(key: bytes, value: str) -> bytes:
    return hmac.new(key, value.encode("utf-8"), hashlib.sha256).digest()


def sign_with_names(
    method: str,
    path: str,
    params,
    body: bytes,
    headers: dict[str, str],
    host: str,
    signed_names: list[str],
) -> dict[str, str]:
    """Independent SigV4 signer whose SignedHeaders order is controllable."""
    now = datetime.now(timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = amz_date[:8]
    payload_hash = hashlib.sha256(body).hexdigest()
    all_headers = {
        "host": host,
        "x-amz-date": amz_date,
        "x-amz-content-sha256": payload_hash,
    }
    for name, value in headers.items():
        all_headers[name.lower()] = " ".join(value.split())

    canonical_headers = "".join(
        f"{name}:{all_headers[name]}\n" for name in signed_names
    )
    canonical_query = "&".join(
        sorted(
            f"{quote(str(name), safe='-_.~')}={quote(str(value), safe='-_.~')}"
            for name, value in params
        )
    )
    canonical_request = "\n".join(
        [
            method,
            encode_path(path),
            canonical_query,
            canonical_headers,
            ";".join(signed_names),
            payload_hash,
        ]
    )
    scope = f"{date_stamp}/{REGION}/s3/aws4_request"
    string_to_sign = "\n".join(
        [
            "AWS4-HMAC-SHA256",
            amz_date,
            scope,
            hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
        ]
    )
    key = ("AWS4" + SECRET).encode("utf-8")
    for part in (date_stamp, REGION, "s3", "aws4_request"):
        key = _hmac(key, part)
    signature = hmac.new(key, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
    result = dict(all_headers)
    result["Authorization"] = (
        f"AWS4-HMAC-SHA256 Credential={AKID}/{scope}, "
        f"SignedHeaders={';'.join(signed_names)}, Signature={signature}"
    )
    return result


class AuditMockS3RegressionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.data_dir = tempfile.mkdtemp(prefix="mock-s3-audit-")
        self.addCleanup(shutil.rmtree, self.data_dir, True)
        config = mock_s3.Config(port=0, data_dir=self.data_dir, quiet=True)
        self.server, self.thread = mock_s3.start_in_thread(config)
        self.addCleanup(mock_s3.stop_server, self.server, self.thread)
        self.port = self.server.server_address[1]
        self.prefix = f"audit/{self._testMethodName}/"

    def request(
        self,
        method: str,
        path: str,
        params=(),
        body: bytes | None = None,
        headers: dict[str, str] | None = None,
        signed_names: list[str] | None = None,
    ) -> tuple[int, dict[str, str], bytes]:
        payload = body or b""
        host = f"127.0.0.1:{self.port}"
        supplied = dict(headers or {})
        if signed_names is None:
            signed_names = sorted(
                ["host", "x-amz-date", "x-amz-content-sha256"]
                + [name.lower() for name in supplied]
            )
        signed = sign_with_names(
            method, path, params, payload, supplied, host, signed_names
        )
        target = encode_path(path)
        if params:
            target += "?" + encode_query(params)
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            connection.request(method, target, body=payload, headers=signed)
            response = connection.getresponse()
            return (
                response.status,
                {name.lower(): value for name, value in response.getheaders()},
                response.read(),
            )
        finally:
            connection.close()

    def put(self, key: str, body: bytes) -> None:
        status, _, response_body = self.request(
            "PUT", f"/{BUCKET}/{key}", body=body, headers={"Content-Type": "text/plain"}
        )
        self.assertEqual(status, 200, response_body)

    def list(self, *extra) -> ET.Element:
        status, _, body = self.request(
            "GET", f"/{BUCKET}", [("list-type", "2"), ("prefix", self.prefix), *extra]
        )
        self.assertEqual(status, 200, body)
        return ET.fromstring(body)

    @staticmethod
    def keys(root: ET.Element) -> list[str]:
        return [element.text or "" for element in root.findall("s3:Contents/s3:Key", NS)]

    def test_list_delimiter_returns_common_prefixes(self) -> None:
        self.put(f"{self.prefix}dir/a.txt", b"a")
        self.put(f"{self.prefix}dir/b.txt", b"b")
        self.put(f"{self.prefix}root.txt", b"root")
        self.put(f"{self.prefix}z.txt", b"z")

        root = self.list(("delimiter", "/"))
        common = [
            element.text or ""
            for element in root.findall("s3:CommonPrefixes/s3:Prefix", NS)
        ]
        self.assertEqual(
            self.keys(root),
            [f"{self.prefix}root.txt", f"{self.prefix}z.txt"],
        )
        self.assertEqual(common, [f"{self.prefix}dir/"])

    def test_list_start_after_is_applied(self) -> None:
        self.put(f"{self.prefix}a.txt", b"a")
        self.put(f"{self.prefix}root.txt", b"root")
        self.put(f"{self.prefix}z.txt", b"z")

        root = self.list(("start-after", f"{self.prefix}root.txt"))
        self.assertEqual(
            self.keys(root),
            [f"{self.prefix}z.txt"],
        )

    def test_list_start_after_filters_common_prefixes(self) -> None:
        self.prefix = "probe/"
        self.put("probe/a/1", b"1")
        self.put("probe/a/2", b"2")

        root = self.list(("delimiter", "/"), ("start-after", "probe/a/1"))
        common = [
            element.text or ""
            for element in root.findall("s3:CommonPrefixes/s3:Prefix", NS)
        ]
        self.assertEqual(self.keys(root), [])
        self.assertEqual(common, [])

    def test_if_none_match_returns_304_without_a_body(self) -> None:
        key = f"{self.prefix}conditional.txt"
        self.put(key, b"current")
        status, head_headers, body = self.request("HEAD", f"/{BUCKET}/{key}")
        self.assertEqual(status, 200, body)
        etag = head_headers["etag"]

        status, headers, body = self.request(
            "GET", f"/{BUCKET}/{key}", headers={"If-None-Match": etag}
        )
        self.assertEqual(status, 304)
        self.assertEqual(body, b"")
        self.assertEqual(headers.get("etag"), etag)

    def test_sigv4_rejects_a_request_that_does_not_sign_host(self) -> None:
        key = f"{self.prefix}signed.txt"
        self.put(key, b"data")
        status, _, body = self.request(
            "GET",
            f"/{BUCKET}/{key}",
            signed_names=["x-amz-content-sha256", "x-amz-date"],
        )
        self.assertEqual(status, 400, body)
        root = ET.fromstring(body)
        self.assertEqual(root.findtext("Code"), "AuthorizationHeaderMalformed")

    def test_sigv4_rejects_unsorted_signed_headers(self) -> None:
        key = f"{self.prefix}unsorted.txt"
        self.put(key, b"data")
        status, _, body = self.request(
            "GET",
            f"/{BUCKET}/{key}",
            signed_names=["x-amz-date", "host", "x-amz-content-sha256"],
        )
        self.assertEqual(status, 400, body)
        root = ET.fromstring(body)
        self.assertEqual(root.findtext("Code"), "AuthorizationHeaderMalformed")

    def test_concurrent_overwrite_keeps_bytes_and_metadata_consistent(self) -> None:
        race_dir = tempfile.mkdtemp(prefix="mock-s3-race-")
        self.addCleanup(shutil.rmtree, race_dir, True)
        store = mock_s3.ObjectStore(race_dir, BUCKET)
        key = f"{self.prefix}same-key.txt"
        original_commit = store._commit
        first_waiting = threading.Event()
        second_committed = threading.Event()
        errors: queue.Queue[BaseException] = queue.Queue()

        def delayed_commit(key: str, size: int, etag: str, content_type: str) -> dict:
            if threading.current_thread().name == "first-writer":
                first_waiting.set()
                if not second_committed.wait(timeout=5):
                    raise TimeoutError("second writer never committed")
            result = original_commit(key, size, etag, content_type)
            if threading.current_thread().name == "second-writer":
                second_committed.set()
            return result

        store._commit = delayed_commit

        def write(name: str, body: bytes) -> None:
            try:
                store.put(key, body, "text/plain")
            except BaseException as error:  # reported in the test thread
                errors.put(error)

        first = threading.Thread(target=write, args=("first-writer", b"first"), name="first-writer")
        second = threading.Thread(
            target=write, args=("second-writer", b"second-version"), name="second-writer"
        )
        first.start()
        try:
            self.assertTrue(first_waiting.wait(timeout=5))
            second.start()
            second.join(timeout=5)
            first.join(timeout=5)
        finally:
            second_committed.set()
            first.join(timeout=5)
            if second.is_alive():
                second.join(timeout=5)

        self.assertFalse(first.is_alive())
        self.assertFalse(second.is_alive())
        self.assertTrue(errors.empty(), list(errors.queue))
        found = store.get(key)
        self.assertIsNotNone(found)
        item, body = found
        self.assertEqual(item["size"], len(body))
        self.assertEqual(item["etag"], hashlib.md5(body).hexdigest())


if __name__ == "__main__":
    unittest.main(verbosity=2)
