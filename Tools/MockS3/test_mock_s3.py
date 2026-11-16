#!/usr/bin/env python3
"""Integration tests for the mock S3 server.

Run with:

    python3 Tools/MockS3/test_mock_s3.py
    python3 -m unittest discover -s Tools/MockS3 -p 'test_*.py'

The SigV4 signer below is written from the AWS specification and shares no code
with the server's verifier, so a bug in the verifier cannot hide itself.
"""

from __future__ import annotations

import hashlib
import hmac
import http.client
import json
import os
import shutil
import sys
import tempfile
import time
import unittest
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from urllib.parse import quote

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import mock_s3  # noqa: E402 - only used to run the server

AKID = "testkey"
SECRET = "testsecret"
REGION = "us-east-1"
BUCKET = "backu-test"
XMLNS = "http://s3.amazonaws.com/doc/2006-03-01/"
NS = {"s3": XMLNS}

AUTH_PORT = 0
NOAUTH_PORT = 0
AUTH_DATA_DIR = ""
NOAUTH_DATA_DIR = ""
_AUTH_SERVER = None
_AUTH_THREAD = None
_NOAUTH_SERVER = None
_NOAUTH_THREAD = None


# --------------------------------------------------------------------------- #
# independent SigV4 signer
# --------------------------------------------------------------------------- #


def _encode(value: str, keep_slash: bool = False) -> str:
    safe = "-_.~" + ("/" if keep_slash else "")
    return quote(value, safe=safe, encoding="utf-8", errors="strict")


def encode_path(path: str) -> str:
    return "/".join(_encode(segment) for segment in path.split("/"))


def encode_query(params) -> str:
    return "&".join(f"{_encode(str(k))}={_encode(str(v))}" for k, v in params)


def canonical_query(params) -> str:
    pairs = sorted((_encode(str(k)), _encode(str(v))) for k, v in params)
    return "&".join(f"{k}={v}" for k, v in pairs)


def _hmac(key: bytes, message: str) -> bytes:
    return hmac.new(key, message.encode("utf-8"), hashlib.sha256).digest()


def sign(
    method: str,
    path: str,
    params=(),
    body: bytes = b"",
    headers: dict[str, str] | None = None,
    host: str = "",
    when: datetime | None = None,
    access_key: str = AKID,
    secret: str = SECRET,
    region: str = REGION,
) -> dict[str, str]:
    when = when or datetime.now(timezone.utc)
    amz_date = when.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = amz_date[:8]
    payload_hash = hashlib.sha256(body).hexdigest()

    all_headers: dict[str, str] = {
        "host": host,
        "x-amz-date": amz_date,
        "x-amz-content-sha256": payload_hash,
    }
    for name, value in (headers or {}).items():
        all_headers[name.lower()] = " ".join(value.split())

    signed_names = ";".join(sorted(all_headers))
    canonical_headers = "".join(f"{name}:{all_headers[name]}\n" for name in sorted(all_headers))

    canonical_request = "\n".join(
        [
            method,
            encode_path(path),
            canonical_query(params),
            canonical_headers,
            signed_names,
            payload_hash,
        ]
    )
    scope = f"{date_stamp}/{region}/s3/aws4_request"
    string_to_sign = "\n".join(
        [
            "AWS4-HMAC-SHA256",
            amz_date,
            scope,
            hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
        ]
    )
    key = ("AWS4" + secret).encode("utf-8")
    for part in (date_stamp, region, "s3", "aws4_request"):
        key = _hmac(key, part)
    signature = hmac.new(key, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()

    result = dict(all_headers)
    result["Authorization"] = (
        f"AWS4-HMAC-SHA256 Credential={access_key}/{scope}, "
        f"SignedHeaders={signed_names}, Signature={signature}"
    )
    return result


# --------------------------------------------------------------------------- #
# request helper
# --------------------------------------------------------------------------- #


class Response:
    def __init__(self, status: int, headers: dict[str, str], body: bytes) -> None:
        self.status = status
        self.headers = headers
        self.body = body

    def xml(self) -> ET.Element:
        return ET.fromstring(self.body)

    def error(self) -> dict[str, str]:
        root = self.xml()
        return {
            "code": root.findtext("Code"),
            "message": root.findtext("Message"),
            "request_id": root.findtext("RequestId"),
        }


def call(
    method: str,
    path: str,
    params=(),
    body: bytes | None = None,
    content_type: str | None = None,
    port: int | None = None,
    host: str | None = None,
    sign_it: bool = True,
    secret: str = SECRET,
    access_key: str = AKID,
    when: datetime | None = None,
    extra_headers: dict[str, str] | None = None,
    tamper_signature: bool = False,
) -> Response:
    port = AUTH_PORT if port is None else port
    payload = body or b""
    headers: dict[str, str] = {}
    if content_type:
        headers["Content-Type"] = content_type
    for name, value in (extra_headers or {}).items():
        headers[name.lower()] = value

    host = host or f"127.0.0.1:{port}"
    if sign_it:
        headers = sign(
            method,
            path,
            params,
            payload,
            headers,
            host=host,
            when=when,
            access_key=access_key,
            secret=secret,
        )
        if tamper_signature:
            headers["Authorization"] = headers["Authorization"][:-4] + "0000"

    target = encode_path(path)
    if params:
        target += "?" + encode_query(params)

    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        connection.request(
            method,
            target,
            body=payload if body is not None else None,
            headers=headers,
        )
        raw = connection.getresponse()
        data = raw.read()
        return Response(raw.status, {k.lower(): v for k, v in raw.getheaders()}, data)
    finally:
        connection.close()


def parse_list(response: Response) -> dict:
    root = response.xml()
    contents = []
    for element in root.findall("s3:Contents", NS):
        contents.append(
            {
                "key": element.findtext("s3:Key", namespaces=NS),
                "last_modified": element.findtext("s3:LastModified", namespaces=NS),
                "etag": element.findtext("s3:ETag", namespaces=NS),
                "size": element.findtext("s3:Size", namespaces=NS),
                "storage_class": element.findtext("s3:StorageClass", namespaces=NS),
            }
        )
    return {
        "name": root.findtext("s3:Name", namespaces=NS),
        "prefix": root.findtext("s3:Prefix", namespaces=NS),
        "key_count": int(root.findtext("s3:KeyCount", namespaces=NS)),
        "max_keys": int(root.findtext("s3:MaxKeys", namespaces=NS)),
        "is_truncated": root.findtext("s3:IsTruncated", namespaces=NS) == "true",
        "next_token": root.findtext("s3:NextContinuationToken", namespaces=NS),
        "contents": contents,
    }


def list_v2(prefix: str, max_keys: int | None = None, token: str | None = None, **kwargs) -> Response:
    params = [("list-type", "2")]
    if max_keys is not None:
        params.append(("max-keys", str(max_keys)))
    params.append(("prefix", prefix))
    if token:
        params.append(("continuation-token", token))
    return call("GET", f"/{BUCKET}", params, **kwargs)


# --------------------------------------------------------------------------- #
# module fixtures
# --------------------------------------------------------------------------- #


def setUpModule() -> None:
    global AUTH_PORT, NOAUTH_PORT, AUTH_DATA_DIR, NOAUTH_DATA_DIR
    global _AUTH_SERVER, _AUTH_THREAD, _NOAUTH_SERVER, _NOAUTH_THREAD

    AUTH_DATA_DIR = tempfile.mkdtemp(prefix="mock-s3-test-auth-")
    NOAUTH_DATA_DIR = tempfile.mkdtemp(prefix="mock-s3-test-noauth-")

    auth_config = mock_s3.Config(port=0, data_dir=AUTH_DATA_DIR, quiet=True)
    _AUTH_SERVER, _AUTH_THREAD = mock_s3.start_in_thread(auth_config)
    AUTH_PORT = _AUTH_SERVER.server_address[1]

    noauth_config = mock_s3.Config(port=0, data_dir=NOAUTH_DATA_DIR, require_auth=False, quiet=True)
    _NOAUTH_SERVER, _NOAUTH_THREAD = mock_s3.start_in_thread(noauth_config)
    NOAUTH_PORT = _NOAUTH_SERVER.server_address[1]


def tearDownModule() -> None:
    for server, thread in ((_AUTH_SERVER, _AUTH_THREAD), (_NOAUTH_SERVER, _NOAUTH_THREAD)):
        if server is not None:
            mock_s3.stop_server(server, thread)
    shutil.rmtree(AUTH_DATA_DIR, ignore_errors=True)
    shutil.rmtree(NOAUTH_DATA_DIR, ignore_errors=True)


class MockS3TestCase(unittest.TestCase):
    def setUp(self) -> None:
        # every test owns a prefix so tests cannot see each other's objects
        self.prefix = f"tests/{self._testMethodName}/"

    def put(self, key: str, body: bytes, content_type: str = "application/octet-stream", **kwargs) -> Response:
        return call("PUT", f"/{BUCKET}/{key}", body=body, content_type=content_type, **kwargs)

    def get(self, key: str, **kwargs) -> Response:
        return call("GET", f"/{BUCKET}/{key}", **kwargs)

    def head(self, key: str, **kwargs) -> Response:
        return call("HEAD", f"/{BUCKET}/{key}", **kwargs)

    def delete(self, key: str, **kwargs) -> Response:
        return call("DELETE", f"/{BUCKET}/{key}", **kwargs)


# --------------------------------------------------------------------------- #
# tests
# --------------------------------------------------------------------------- #


class RoundTripTests(MockS3TestCase):
    def test_put_get_head(self) -> None:
        key = f"{self.prefix}photo.jpg"
        payload = b"\xff\xd8\xff\xe0" + bytes(range(256)) * 3 + b"\xff\xd9"

        put = self.put(key, payload, content_type="image/jpeg")
        self.assertEqual(put.status, 200, put.body)
        expected_etag = '"' + hashlib.md5(payload).hexdigest() + '"'
        self.assertEqual(put.headers["etag"], expected_etag)

        get = self.get(key)
        self.assertEqual(get.status, 200, get.body)
        self.assertEqual(get.body, payload)
        self.assertEqual(get.headers["content-type"], "image/jpeg")
        self.assertEqual(get.headers["content-length"], str(len(payload)))
        self.assertEqual(get.headers["etag"], expected_etag)

        head = self.head(key)
        self.assertEqual(head.status, 200)
        self.assertEqual(head.body, b"")
        self.assertEqual(head.headers["content-length"], str(len(payload)))
        self.assertEqual(head.headers["etag"], expected_etag)
        self.assertEqual(head.headers["content-type"], "image/jpeg")

    def test_put_empty_object(self) -> None:
        key = f"{self.prefix}empty.txt"
        self.assertEqual(self.put(key, b"", content_type="text/plain").status, 200)
        got = self.get(key)
        self.assertEqual(got.status, 200)
        self.assertEqual(got.body, b"")
        self.assertEqual(got.headers["etag"], '"d41d8cd98f00b204e9800998ecf8427e"')

    def test_overwrite_replaces_content(self) -> None:
        key = f"{self.prefix}versioned.txt"
        self.put(key, b"first", content_type="text/plain")
        self.put(key, b"second", content_type="text/plain")
        got = self.get(key)
        self.assertEqual(got.body, b"second")
        listed = parse_list(list_v2(self.prefix))
        self.assertEqual([entry["key"] for entry in listed["contents"]], [key])

    def test_unicode_and_spaced_key(self) -> None:
        key = f"{self.prefix}héllo wörld ☃.jpg"
        payload = "contenu accentué ✓".encode("utf-8")

        self.assertEqual(self.put(key, payload, content_type="image/jpeg").status, 200)
        got = self.get(key)
        self.assertEqual(got.status, 200)
        self.assertEqual(got.body, payload)

        head = self.head(key)
        self.assertEqual(head.status, 200)
        self.assertEqual(head.headers["content-length"], str(len(payload)))

        listed = parse_list(list_v2(self.prefix))
        self.assertEqual([entry["key"] for entry in listed["contents"]], [key])

        self.assertEqual(self.delete(key).status, 204)
        self.assertEqual(self.head(key).status, 404)

    def test_percent_and_plus_in_key(self) -> None:
        key = f"{self.prefix}100% done+final?.txt"
        payload = b"odd characters"
        self.assertEqual(self.put(key, payload, content_type="text/plain").status, 200)
        got = self.get(key)
        self.assertEqual(got.status, 200)
        self.assertEqual(got.body, payload)


class HeadAndMissingTests(MockS3TestCase):
    def test_head_missing_is_404_without_body(self) -> None:
        response = self.head(f"{self.prefix}absent.jpg")
        self.assertEqual(response.status, 404)
        self.assertEqual(response.body, b"")

    def test_get_missing_returns_nosuchkey_xml(self) -> None:
        response = self.get(f"{self.prefix}absent.jpg")
        self.assertEqual(response.status, 404)
        error = response.error()
        self.assertEqual(error["code"], "NoSuchKey")
        self.assertTrue(error["message"])
        self.assertTrue(error["request_id"])

    def test_delete_missing_is_204(self) -> None:
        self.assertEqual(self.delete(f"{self.prefix}never-existed.jpg").status, 204)

    def test_unknown_bucket(self) -> None:
        response = call("GET", "/some-other-bucket/key.txt")
        self.assertEqual(response.status, 404)
        self.assertEqual(response.error()["code"], "NoSuchBucket")


class ListTests(MockS3TestCase):
    def test_list_prefix_and_sorting(self) -> None:
        keys = [f"{self.prefix}b.jpg", f"{self.prefix}a.jpg", f"{self.prefix}c.jpg"]
        for key in keys:
            self.put(key, key.encode(), content_type="image/jpeg")
        self.put(f"{self.prefix}nested/d.jpg", b"d", content_type="image/jpeg")
        self.put("tests/other-test/x.jpg", b"x", content_type="image/jpeg")

        listed = parse_list(list_v2(self.prefix))
        self.assertEqual(listed["name"], BUCKET)
        self.assertEqual(listed["prefix"], self.prefix)
        self.assertEqual(listed["key_count"], 4)
        self.assertEqual(listed["max_keys"], 1000)
        self.assertFalse(listed["is_truncated"])
        self.assertIsNone(listed["next_token"])
        self.assertEqual(
            [entry["key"] for entry in listed["contents"]],
            [
                f"{self.prefix}a.jpg",
                f"{self.prefix}b.jpg",
                f"{self.prefix}c.jpg",
                f"{self.prefix}nested/d.jpg",
            ],
        )

        first = listed["contents"][0]
        self.assertRegex(first["last_modified"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")
        self.assertRegex(first["etag"], r'^"[0-9a-f]{32}"$')
        self.assertEqual(first["size"], str(len(f"{self.prefix}a.jpg")))
        self.assertEqual(first["storage_class"], "STANDARD")

    def test_list_narrow_prefix(self) -> None:
        self.put(f"{self.prefix}2024/a.jpg", b"a")
        self.put(f"{self.prefix}2024/b.jpg", b"b")
        self.put(f"{self.prefix}2025/c.jpg", b"c")
        listed = parse_list(list_v2(f"{self.prefix}2024/"))
        self.assertEqual(listed["key_count"], 2)
        self.assertEqual(
            [entry["key"] for entry in listed["contents"]],
            [f"{self.prefix}2024/a.jpg", f"{self.prefix}2024/b.jpg"],
        )

    def test_list_pagination(self) -> None:
        keys = [f"{self.prefix}{index}.jpg" for index in range(3)]
        for key in keys:
            self.put(key, key.encode())

        collected: list[str] = []
        token = None
        pages = 0
        while True:
            listed = parse_list(list_v2(self.prefix, max_keys=1, token=token))
            pages += 1
            self.assertEqual(listed["max_keys"], 1)
            self.assertEqual(listed["key_count"], len(listed["contents"]))
            self.assertLessEqual(len(listed["contents"]), 1)
            collected.extend(entry["key"] for entry in listed["contents"])
            if not listed["is_truncated"]:
                self.assertIsNone(listed["next_token"])
                break
            self.assertIsNotNone(listed["next_token"])
            self.assertNotEqual(listed["next_token"], token)
            token = listed["next_token"]
            self.assertLess(pages, 10, "pagination did not terminate")

        self.assertEqual(pages, 3)
        self.assertEqual(collected, keys)

    def test_list_empty_prefix_has_no_entries(self) -> None:
        listed = parse_list(list_v2(f"{self.prefix}does-not-exist/"))
        self.assertEqual(listed["key_count"], 0)
        self.assertEqual(listed["contents"], [])
        self.assertFalse(listed["is_truncated"])

    def test_list_max_keys_zero(self) -> None:
        self.put(f"{self.prefix}a.jpg", b"a")
        listed = parse_list(list_v2(self.prefix, max_keys=0))
        self.assertEqual(listed["key_count"], 0)
        self.assertEqual(listed["max_keys"], 0)
        self.assertFalse(listed["is_truncated"])

    def test_list_ignores_query_order(self) -> None:
        self.put(f"{self.prefix}a.jpg", b"a")
        # deliberately unsorted params: the signature sorts them canonically
        params = [
            ("prefix", self.prefix),
            ("list-type", "2"),
            ("max-keys", "10"),
        ]
        response = call("GET", f"/{BUCKET}", params)
        self.assertEqual(response.status, 200, response.body)
        self.assertEqual(parse_list(response)["key_count"], 1)

    def test_bogus_continuation_token(self) -> None:
        response = list_v2(self.prefix, token="not-a-real-token!!")
        self.assertEqual(response.status, 400)
        self.assertEqual(response.error()["code"], "InvalidArgument")


class DeleteTests(MockS3TestCase):
    def test_delete_removes_object(self) -> None:
        key = f"{self.prefix}gone.jpg"
        self.put(key, b"bytes")
        self.assertEqual(self.get(key).status, 200)

        response = self.delete(key)
        self.assertEqual(response.status, 204)
        self.assertEqual(response.body, b"")

        self.assertEqual(self.get(key).status, 404)
        self.assertEqual(parse_list(list_v2(self.prefix))["key_count"], 0)


class AuthTests(MockS3TestCase):
    def test_unsigned_request_is_denied(self) -> None:
        response = call("GET", f"/{BUCKET}/{self.prefix}x.jpg", sign_it=False)
        self.assertEqual(response.status, 403)
        self.assertEqual(response.error()["code"], "AccessDenied")

    def test_bad_signature_is_rejected(self) -> None:
        key = f"{self.prefix}secret.jpg"
        response = self.put(key, b"payload", secret="not-the-secret")
        self.assertEqual(response.status, 403)
        self.assertEqual(response.error()["code"], "SignatureDoesNotMatch")
        self.assertEqual(self.head(key).status, 404, "a rejected write must not store anything")

    def test_tampered_signature_is_rejected(self) -> None:
        response = self.put(f"{self.prefix}x.jpg", b"payload", tamper_signature=True)
        self.assertEqual(response.status, 403)
        self.assertEqual(response.error()["code"], "SignatureDoesNotMatch")

    def test_wrong_access_key(self) -> None:
        response = call("GET", f"/{BUCKET}/{self.prefix}x.jpg", access_key="someone-else")
        self.assertEqual(response.status, 403)
        self.assertEqual(response.error()["code"], "InvalidAccessKeyId")

    def test_clock_skew_is_rejected(self) -> None:
        past = datetime.now(timezone.utc) - timedelta(minutes=20)
        response = call("GET", f"/{BUCKET}/{self.prefix}x.jpg", when=past)
        self.assertEqual(response.status, 400)
        self.assertEqual(response.error()["code"], "RequestTimeTooSkewed")

        future = datetime.now(timezone.utc) + timedelta(minutes=20)
        response = call("GET", f"/{BUCKET}/{self.prefix}x.jpg", when=future)
        self.assertEqual(response.status, 400)
        self.assertEqual(response.error()["code"], "RequestTimeTooSkewed")

    def test_small_clock_skew_is_accepted(self) -> None:
        slightly_old = datetime.now(timezone.utc) - timedelta(minutes=5)
        self.assertEqual(
            call("GET", f"/{BUCKET}/{self.prefix}x.jpg", when=slightly_old).status,
            404,
        )

    def test_body_hash_mismatch_is_rejected(self) -> None:
        key = f"{self.prefix}mismatch.txt"
        # sign for one body, send another
        headers = sign("PUT", f"/{BUCKET}/{key}", body=b"what was signed", host=f"127.0.0.1:{AUTH_PORT}")
        headers["Content-Type"] = "text/plain"
        connection = http.client.HTTPConnection("127.0.0.1", AUTH_PORT, timeout=10)
        try:
            connection.request("PUT", f"/{BUCKET}/{encode_path(key)}", body=b"something else", headers=headers)
            raw = connection.getresponse()
            raw.read()
            self.assertEqual(raw.status, 400)
        finally:
            connection.close()
        self.assertEqual(self.head(key).status, 404)

    def test_head_and_delete_require_valid_signature(self) -> None:
        key = f"{self.prefix}signed.jpg"
        self.assertEqual(self.put(key, b"bytes").status, 200)

        head = call("HEAD", f"/{BUCKET}/{key}", secret="wrong-secret")
        self.assertEqual(head.status, 403)
        self.assertEqual(head.body, b"")

        delete = call("DELETE", f"/{BUCKET}/{key}", secret="wrong-secret")
        self.assertEqual(delete.status, 403)
        self.assertEqual(delete.error()["code"], "SignatureDoesNotMatch")
        self.assertEqual(self.get(key).status, 200, "a rejected delete must not remove the object")

    def test_virtual_host_style(self) -> None:
        key = f"{self.prefix}vhost.txt"
        host = f"{BUCKET}.127.0.0.1:{AUTH_PORT}"
        payload = b"virtual host style"
        put = call("PUT", f"/{key}", body=payload, content_type="text/plain", host=host)
        self.assertEqual(put.status, 200, put.body)
        got = call("GET", f"/{key}", host=host)
        self.assertEqual(got.status, 200)
        self.assertEqual(got.body, payload)
        listed = parse_list(call("GET", "/", [("list-type", "2"), ("prefix", self.prefix)], host=host))
        self.assertEqual([entry["key"] for entry in listed["contents"]], [key])


class NoAuthTests(MockS3TestCase):
    def test_unsigned_requests_work_when_auth_is_disabled(self) -> None:
        key = f"{self.prefix}unsigned.txt"
        put = call("PUT", f"/{BUCKET}/{key}", body=b"no signature", sign_it=False, port=NOAUTH_PORT)
        self.assertEqual(put.status, 200, put.body)

        got = call("GET", f"/{BUCKET}/{key}", sign_it=False, port=NOAUTH_PORT)
        self.assertEqual(got.status, 200)
        self.assertEqual(got.body, b"no signature")

        head = call("HEAD", f"/{BUCKET}/{key}", sign_it=False, port=NOAUTH_PORT)
        self.assertEqual(head.status, 200)
        self.assertEqual(head.headers["content-length"], str(len(b"no signature")))

        listed = call(
            "GET",
            f"/{BUCKET}",
            [("list-type", "2"), ("prefix", self.prefix)],
            sign_it=False,
            port=NOAUTH_PORT,
        )
        self.assertEqual(parse_list(listed)["key_count"], 1)


class ConcurrencyTests(MockS3TestCase):
    def test_parallel_write_read_delete(self) -> None:
        count = 24

        def worker(index: int) -> tuple[int, int, bool]:
            key = f"{self.prefix}{index:02d}.bin"
            payload = (f"payload-{index}-".encode() * 40) + bytes([index])
            put_status = self.put(key, payload).status
            got = self.get(key)
            return put_status, got.status, got.body == payload

        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(worker, range(count)))

        self.assertEqual(results, [(200, 200, True)] * count)
        listed = parse_list(list_v2(self.prefix))
        self.assertEqual(listed["key_count"], count)
        self.assertEqual(
            [entry["key"] for entry in listed["contents"]],
            [f"{self.prefix}{index:02d}.bin" for index in range(count)],
        )


class StorageLayoutTests(MockS3TestCase):
    def test_upload_is_inspectable_on_disk(self) -> None:
        key = f"{self.prefix}inspect.txt"
        payload = "inspectable ✓".encode("utf-8")
        self.assertEqual(self.put(key, payload, content_type="text/plain; charset=utf-8").status, 200)

        bucket_dir = os.path.join(AUTH_DATA_DIR, BUCKET)
        index_path = os.path.join(bucket_dir, "index.json")
        with open(index_path, "r", encoding="utf-8") as handle:
            index = json.load(handle)
        self.assertIn(key, index)
        entry = index[key]
        self.assertEqual(entry["size"], len(payload))
        self.assertEqual(entry["etag"], hashlib.md5(payload).hexdigest())
        self.assertEqual(entry["contentType"], "text/plain; charset=utf-8")

        with open(os.path.join(bucket_dir, entry["file"]), "rb") as handle:
            self.assertEqual(handle.read(), payload)

        meta_dir = os.path.join(bucket_dir, "meta")
        sidecars = []
        for name in os.listdir(meta_dir):
            with open(os.path.join(meta_dir, name), "r", encoding="utf-8") as handle:
                sidecars.append(json.load(handle))
        self.assertTrue(any(item["key"] == key for item in sidecars))


# --------------------------------------------------------------------------- #
# multipart
# --------------------------------------------------------------------------- #


def _upload_id(response: Response) -> str:
    root = response.xml()
    return root.findtext("s3:UploadId", namespaces=NS) or ""


def _complete_body(parts: list[tuple[int, str]]) -> bytes:
    items = "".join(
        f"<Part><PartNumber>{number}</PartNumber><ETag>{etag}</ETag></Part>"
        for number, etag in parts
    )
    return f"<CompleteMultipartUpload>{items}</CompleteMultipartUpload>".encode("utf-8")


class MultipartTests(MockS3TestCase):
    def create(self, key: str) -> str:
        response = call("POST", f"/{BUCKET}/{key}", [("uploads", "")])
        self.assertEqual(response.status, 200, response.body)
        upload_id = _upload_id(response)
        self.assertTrue(upload_id)
        return upload_id

    def upload_part(self, key: str, upload_id: str, number: int, body: bytes, **kwargs) -> Response:
        return call(
            "PUT",
            f"/{BUCKET}/{key}",
            [("partNumber", str(number)), ("uploadId", upload_id)],
            body=body,
            **kwargs,
        )

    def test_multipart_round_trip(self) -> None:
        key = f"{self.prefix}large.bin"
        first = b"A" * (5 * 1024 * 1024)
        second = b"B" * 1234

        upload_id = self.create(key)
        part_one = self.upload_part(key, upload_id, 1, first)
        part_two = self.upload_part(key, upload_id, 2, second)
        self.assertEqual(part_one.status, 200, part_one.body)
        self.assertEqual(part_two.status, 200, part_two.body)
        etag_one = part_one.headers["etag"]
        etag_two = part_two.headers["etag"]
        self.assertEqual(etag_one, '"' + hashlib.md5(first).hexdigest() + '"')
        self.assertEqual(etag_two, '"' + hashlib.md5(second).hexdigest() + '"')

        listed = call("GET", f"/{BUCKET}/{key}", [("uploadId", upload_id)])
        self.assertEqual(listed.status, 200, listed.body)
        root = listed.xml()
        parts = [
            {
                "number": int(element.findtext("s3:PartNumber", namespaces=NS)),
                "etag": element.findtext("s3:ETag", namespaces=NS),
                "size": int(element.findtext("s3:Size", namespaces=NS)),
            }
            for element in root.findall("s3:Part", NS)
        ]
        self.assertEqual(parts, [
            {"number": 1, "etag": etag_one, "size": len(first)},
            {"number": 2, "etag": etag_two, "size": len(second)},
        ])

        completed = call(
            "POST",
            f"/{BUCKET}/{key}",
            [("uploadId", upload_id)],
            body=_complete_body([(1, etag_one), (2, etag_two)]),
            content_type="application/xml",
        )
        self.assertEqual(completed.status, 200, completed.body)
        completed_root = completed.xml()
        self.assertEqual(completed_root.findtext("s3:Key", namespaces=NS), key)
        final_etag = completed_root.findtext("s3:ETag", namespaces=NS)
        self.assertRegex(final_etag, r'^"[0-9a-f]{32}-2"$')

        got = self.get(key)
        self.assertEqual(got.status, 200)
        self.assertEqual(got.body, first + second)
        self.assertEqual(got.headers["content-length"], str(len(first) + len(second)))
        self.assertEqual(got.headers["etag"], final_etag)

        # The upload is gone after completion.
        self.assertEqual(call("GET", f"/{BUCKET}/{key}", [("uploadId", upload_id)]).status, 404)

    def test_multipart_query_parameters_are_signed(self) -> None:
        key = f"{self.prefix}signed-multipart.bin"
        upload_id = self.create(key)
        body = b"x" * 1024
        bad = self.upload_part(key, upload_id, 1, body, secret="wrong-secret")
        self.assertEqual(bad.status, 403)
        self.assertEqual(bad.error()["code"], "SignatureDoesNotMatch")
        tampered = self.upload_part(key, upload_id, 1, body, tamper_signature=True)
        self.assertEqual(tampered.status, 403)
        # A valid request still works after the rejected ones.
        good = self.upload_part(key, upload_id, 1, body)
        self.assertEqual(good.status, 200, good.body)

        unknown = call(
            "POST",
            f"/{BUCKET}/{key}",
            [("uploadId", "not-a-real-upload")],
            body=_complete_body([(1, good.headers["etag"])]),
            content_type="application/xml",
        )
        self.assertEqual(unknown.status, 404)
        self.assertEqual(unknown.error()["code"], "NoSuchUpload")

    def test_abort_removes_parts(self) -> None:
        key = f"{self.prefix}aborted.bin"
        upload_id = self.create(key)
        self.assertEqual(self.upload_part(key, upload_id, 1, b"part").status, 200)
        aborted = call("DELETE", f"/{BUCKET}/{key}", [("uploadId", upload_id)])
        self.assertEqual(aborted.status, 204)
        self.assertEqual(call("GET", f"/{BUCKET}/{key}", [("uploadId", upload_id)]).status, 404)
        self.assertEqual(self.head(key).status, 404)
        # Aborting again is not idempotent in S3, and not in the mock.
        self.assertEqual(call("DELETE", f"/{BUCKET}/{key}", [("uploadId", upload_id)]).status, 404)

    def test_complete_requires_valid_parts(self) -> None:
        key = f"{self.prefix}invalid.bin"
        upload_id = self.create(key)
        etag = self.upload_part(key, upload_id, 1, b"part").headers["etag"]
        missing = call(
            "POST",
            f"/{BUCKET}/{key}",
            [("uploadId", upload_id)],
            body=_complete_body([(2, etag)]),
            content_type="application/xml",
        )
        self.assertEqual(missing.status, 400)
        self.assertEqual(missing.error()["code"], "InvalidPart")

        wrong_etag = call(
            "POST",
            f"/{BUCKET}/{key}",
            [("uploadId", upload_id)],
            body=_complete_body([(1, '"00000000000000000000000000000000"')]),
            content_type="application/xml",
        )
        self.assertEqual(wrong_etag.status, 400)
        self.assertEqual(wrong_etag.error()["code"], "InvalidPart")

        out_of_order = call(
            "POST",
            f"/{BUCKET}/{key}",
            [("uploadId", upload_id)],
            body=_complete_body([(2, etag), (1, etag)]),
            content_type="application/xml",
        )
        self.assertEqual(out_of_order.status, 400)
        self.assertEqual(out_of_order.error()["code"], "InvalidPartOrder")

    def test_non_final_part_below_five_mib_is_rejected(self) -> None:
        key = f"{self.prefix}small-first.bin"
        upload_id = self.create(key)
        first = self.upload_part(key, upload_id, 1, b"tiny").headers["etag"]
        second = self.upload_part(key, upload_id, 2, b"tiny too").headers["etag"]
        response = call(
            "POST",
            f"/{BUCKET}/{key}",
            [("uploadId", upload_id)],
            body=_complete_body([(1, first), (2, second)]),
            content_type="application/xml",
        )
        self.assertEqual(response.status, 400)
        self.assertEqual(response.error()["code"], "EntityTooSmall")


class RangeTests(MockS3TestCase):
    def setUp(self) -> None:
        super().setUp()
        self.key = f"{self.prefix}range.bin"
        self.payload = bytes(range(256)) * 4  # 1024 deterministic bytes
        self.assertEqual(self.put(self.key, self.payload).status, 200)

    def test_range_returns_206_and_headers(self) -> None:
        response = call("GET", f"/{BUCKET}/{self.key}", extra_headers={"Range": "bytes=10-19"})
        self.assertEqual(response.status, 206, response.body)
        self.assertEqual(response.headers["content-range"], f"bytes 10-19/{len(self.payload)}")
        self.assertEqual(response.headers["content-length"], "10")
        self.assertEqual(response.headers["accept-ranges"], "bytes")
        self.assertEqual(response.body, self.payload[10:20])

    def test_open_ended_range(self) -> None:
        response = call("GET", f"/{BUCKET}/{self.key}", extra_headers={"Range": "bytes=1000-"})
        self.assertEqual(response.status, 206)
        self.assertEqual(response.body, self.payload[1000:])
        self.assertEqual(response.headers["content-range"], f"bytes 1000-1023/{len(self.payload)}")

    def test_suffix_range(self) -> None:
        response = call("GET", f"/{BUCKET}/{self.key}", extra_headers={"Range": "bytes=-24"})
        self.assertEqual(response.status, 206)
        self.assertEqual(response.body, self.payload[-24:])
        self.assertEqual(response.headers["content-range"], f"bytes 1000-1023/{len(self.payload)}")

    def test_head_advertises_ranges(self) -> None:
        response = self.head(self.key)
        self.assertEqual(response.status, 200)
        self.assertEqual(response.headers["accept-ranges"], "bytes")
        self.assertEqual(response.headers["content-length"], str(len(self.payload)))

    def test_unsatisfiable_range_is_416(self) -> None:
        response = call("GET", f"/{BUCKET}/{self.key}", extra_headers={"Range": "bytes=5000-6000"})
        self.assertEqual(response.status, 416)
        self.assertEqual(response.error()["code"], "InvalidRange")
        self.assertEqual(response.headers["content-range"], f"bytes */{len(self.payload)}")


# --------------------------------------------------------------------------- #
# shaping and failure injection
# --------------------------------------------------------------------------- #


class ShapingAndFailureTests(unittest.TestCase):
    def _start(self, **overrides):
        data_dir = tempfile.mkdtemp(prefix="mock-s3-shaping-")
        config = mock_s3.Config(port=0, data_dir=data_dir, quiet=True, **overrides)
        server, thread = mock_s3.start_in_thread(config)
        self.addCleanup(shutil.rmtree, data_dir, True)
        self.addCleanup(mock_s3.stop_server, server, thread)
        return server, server.server_address[1]

    def test_injected_failures_are_counted_and_retryable(self) -> None:
        server, port = self._start(fail_rate=1.0, fail_status=503, seed=7)
        response = call("GET", f"/{BUCKET}/tests/fail/x.bin", port=port)
        self.assertEqual(response.status, 503)
        self.assertEqual(response.error()["code"], "ServiceUnavailable")
        self.assertEqual(server.stats["requests"], 1)
        self.assertEqual(server.stats["injected_failures"], 1)

    def test_failure_injection_is_seeded_and_deterministic(self) -> None:
        first_server, first_port = self._start(fail_rate=0.5, fail_status=429, seed=99)
        second_server, second_port = self._start(fail_rate=0.5, fail_status=429, seed=99)
        first = [call("GET", f"/{BUCKET}/tests/seed/{index}.bin", port=first_port).status for index in range(8)]
        second = [call("GET", f"/{BUCKET}/tests/seed/{index}.bin", port=second_port).status for index in range(8)]
        self.assertEqual(first, second)
        self.assertTrue(any(status == 429 for status in first), first)
        self.assertTrue(any(status == 404 for status in first), first)
        self.assertEqual(first_server.stats["injected_failures"], first.count(429))
        self.assertEqual(second_server.stats["injected_failures"], second.count(429))

    def test_retry_after_header_on_429(self) -> None:
        server, port = self._start(fail_rate=1.0, fail_status=429, seed=3)
        response = call("GET", f"/{BUCKET}/tests/retry/x.bin", port=port)
        self.assertEqual(response.status, 429)
        self.assertEqual(response.headers.get("retry-after"), "1")
        self.assertEqual(server.stats["injected_failures"], 1)

    def test_latency_is_applied_per_request(self) -> None:
        server, port = self._start(latency_ms=60)
        started = time.monotonic()
        call("GET", f"/{BUCKET}/tests/latency/x.bin", port=port)
        elapsed = time.monotonic() - started
        self.assertGreaterEqual(elapsed, 0.05)

    def test_bandwidth_bucket_throttles_a_response(self) -> None:
        server, port = self._start(bandwidth_mbps=4.0, require_auth=False)
        payload = b"z" * (256 * 1024)
        put = call("PUT", f"/{BUCKET}/tests/bandwidth/x.bin", body=payload, sign_it=False, port=port)
        self.assertEqual(put.status, 200, put.body)
        started = time.monotonic()
        response = call("GET", f"/{BUCKET}/tests/bandwidth/x.bin", sign_it=False, port=port)
        elapsed = time.monotonic() - started
        self.assertEqual(response.body, payload)
        # 256 KiB at 4 Mbps is about 0.52s; allow generous CI slack.
        self.assertGreaterEqual(elapsed, 0.25)


if __name__ == "__main__":
    unittest.main(verbosity=2)
