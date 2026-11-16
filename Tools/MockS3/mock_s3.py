#!/usr/bin/env python3
"""A tiny, dependency-free mock of the S3 subset Backu uses.

Implements GET (object), GET ?list-type=2 (ListObjectsV2), PUT, DELETE and HEAD,
with real AWS Signature V4 verification, path-style and virtual-host addressing,
and a plain directory on disk for the stored objects.

Run it:

    python3 Tools/MockS3/mock_s3.py --data-dir /tmp/backu-s3

It is a development tool, not a production service: one bucket, no ACLs, no
multipart uploads, no versioning.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import signal
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from email.utils import formatdate, parsedate_to_datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Iterable
from urllib.parse import parse_qsl, quote, unquote
from xml.sax.saxutils import escape

XMLNS = "http://s3.amazonaws.com/doc/2006-03-01/"
EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()
_STREAMING_PAYLOADS = (
    "STREAMING-AWS4-HMAC-SHA256-PAYLOAD",
    "STREAMING-UNSIGNED-PAYLOAD-TRAILER",
    "STREAMING-AWS4-HMAC-SHA256-PAYLOAD-TRAILER",
)
_INVALID_XML = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")

_AUTH_RE = re.compile(
    r"^AWS4-HMAC-SHA256\s+"
    r"Credential=(?P<credential>[^,\s]+)\s*,\s*"
    r"SignedHeaders=(?P<signed_headers>[^,\s]+)\s*,\s*"
    r"Signature=(?P<signature>[0-9a-fA-F]+)\s*$"
)


# --------------------------------------------------------------------------- #
# config
# --------------------------------------------------------------------------- #


@dataclass
class Config:
    host: str = "127.0.0.1"
    port: int = 9000
    bucket: str = "backu-test"
    access_key: str = "testkey"
    secret: str = "testsecret"
    region: str = "us-east-1"
    data_dir: str = ""
    require_auth: bool = True
    quiet: bool = False
    max_skew_seconds: int = 900

    def __post_init__(self) -> None:
        if not self.data_dir:
            self.data_dir = tempfile.mkdtemp(prefix="mock-s3-")
        os.makedirs(self.data_dir, exist_ok=True)


# --------------------------------------------------------------------------- #
# errors
# --------------------------------------------------------------------------- #


class S3Error(Exception):
    """An error that renders as an S3 <Error> document."""

    def __init__(
        self,
        status: int,
        code: str,
        message: str,
        extra: dict[str, str] | None = None,
        debug: list[str] | None = None,
    ) -> None:
        super().__init__(f"{code}: {message}")
        self.status = status
        self.code = code
        self.message = message
        self.extra = extra or {}
        self.debug = debug or []

    def to_xml(self, request_id: str) -> bytes:
        parts = [f"<Code>{_xml_text(self.code)}</Code>", f"<Message>{_xml_text(self.message)}</Message>"]
        for key, value in self.extra.items():
            parts.append(f"<{key}>{_xml_text(value)}</{key}>")
        parts.append(f"<RequestId>{_xml_text(request_id)}</RequestId>")
        body = (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            f"<Error>{''.join(parts)}</Error>\n"
        )
        return body.encode("utf-8")


def _xml_text(value: str) -> str:
    return escape(_INVALID_XML.sub("", value))


# --------------------------------------------------------------------------- #
# SigV4 primitives
# --------------------------------------------------------------------------- #

_URI_SAFE = "-_.~"


def uri_encode(value: str, keep_slash: bool = False) -> str:
    safe = _URI_SAFE + ("/" if keep_slash else "")
    return quote(value, safe=safe, encoding="utf-8", errors="strict")


def canonical_uri(raw_path: str) -> str:
    """Re-encode the raw request path the way SigV4 wants it.

    S3 signs the request target as sent, but with every byte that is not
    unreserved percent-encoded. Decoding and re-encoding each segment gives the
    same bytes as a correct client, and normalises hex case, spaces and
    non-ASCII text (which the Swift client percent-encodes as UTF-8).
    """
    if not raw_path:
        return "/"
    segments = raw_path.split("/")
    encoded = [uri_encode(unquote(segment, encoding="utf-8", errors="replace")) for segment in segments]
    result = "/".join(encoded)
    if not result.startswith("/"):
        result = "/" + result
    return result


def canonical_query(raw_query: str) -> str:
    if not raw_query:
        return ""
    pairs: list[tuple[str, str]] = []
    for part in raw_query.split("&"):
        if not part:
            continue
        if "=" in part:
            raw_name, raw_value = part.split("=", 1)
        else:
            raw_name, raw_value = part, ""
        name = unquote(raw_name, encoding="utf-8", errors="replace")
        value = unquote(raw_value, encoding="utf-8", errors="replace")
        pairs.append((uri_encode(name), uri_encode(value)))
    pairs.sort()
    return "&".join(f"{name}={value}" for name, value in pairs)


def normalize_header_value(value: str) -> str:
    return " ".join(value.split())


def _sign(key: bytes, message: str) -> bytes:
    return hmac.new(key, message.encode("utf-8"), hashlib.sha256).digest()


def signing_key(secret: str, date_stamp: str, region: str, service: str = "s3") -> bytes:
    key = _sign(("AWS4" + secret).encode("utf-8"), date_stamp)
    key = _sign(key, region)
    key = _sign(key, service)
    return _sign(key, "aws4_request")


def _parse_amz_date(value: str) -> datetime:
    try:
        return datetime.strptime(value, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
    except ValueError as error:
        raise S3Error(
            400,
            "AuthorizationHeaderMalformed",
            f"The x-amz-date header is not a valid ISO8601 basic timestamp: {value!r}.",
        ) from error


# --------------------------------------------------------------------------- #
# verification
# --------------------------------------------------------------------------- #


class SigV4Verifier:
    def __init__(self, config: Config) -> None:
        self.config = config

    def verify(
        self,
        method: str,
        raw_path: str,
        raw_query: str,
        headers,
        body: bytes,
    ) -> str:
        """Raises S3Error on failure, returns the access key id on success."""
        config = self.config
        authorization = headers.get("Authorization")
        if not authorization:
            raise S3Error(
                403,
                "AccessDenied",
                "Anonymous access is not allowed; sign the request with SigV4.",
            )

        match = _AUTH_RE.match(authorization.strip())
        if not match:
            raise S3Error(
                400,
                "AuthorizationHeaderMalformed",
                "The authorization header is not in the AWS4-HMAC-SHA256 format.",
                debug=[f"authorization: {authorization!r}"],
            )

        credential = match.group("credential")
        pieces = credential.split("/")
        if len(pieces) != 5:
            raise S3Error(
                400,
                "AuthorizationHeaderMalformed",
                f"The credential scope is malformed: {credential!r}.",
            )
        access_key, scope_date, region, service, terminator = pieces

        if access_key != config.access_key:
            raise S3Error(
                403,
                "InvalidAccessKeyId",
                f"The access key id {access_key!r} does not exist in our records.",
            )
        if region != config.region:
            raise S3Error(
                400,
                "AuthorizationHeaderMalformed",
                f"The region {region!r} is wrong; expecting {config.region!r}.",
                extra={"Region": config.region},
            )
        if service != "s3":
            raise S3Error(
                400,
                "AuthorizationHeaderMalformed",
                f"The service {service!r} is wrong; expecting 's3'.",
            )
        if terminator != "aws4_request":
            raise S3Error(
                400,
                "AuthorizationHeaderMalformed",
                f"The credential scope must end with 'aws4_request', not {terminator!r}.",
            )

        amz_date_header = headers.get("x-amz-date")
        if amz_date_header:
            amz_date = amz_date_header.strip()
            request_time = _parse_amz_date(amz_date)
        else:
            raw_date = headers.get("Date")
            if not raw_date:
                raise S3Error(400, "AccessDenied", "A date header is required.")
            try:
                request_time = parsedate_to_datetime(raw_date.strip())
            except (TypeError, ValueError) as error:
                raise S3Error(400, "AccessDenied", f"The Date header is invalid: {raw_date!r}.") from error
            if request_time.tzinfo is None:
                request_time = request_time.replace(tzinfo=timezone.utc)
            request_time = request_time.astimezone(timezone.utc)
            amz_date = request_time.strftime("%Y%m%dT%H%M%SZ")

        skew = (datetime.now(timezone.utc) - request_time).total_seconds()
        if abs(skew) > config.max_skew_seconds:
            raise S3Error(
                400,
                "RequestTimeTooSkewed",
                "The difference between the request time and the current time is too large.",
                extra={
                    "RequestTime": amz_date,
                    "ServerTime": datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"),
                    "MaxAllowedSkewMilliseconds": str(config.max_skew_seconds * 1000),
                },
            )

        if scope_date != amz_date[:8]:
            raise S3Error(
                403,
                "SignatureDoesNotMatch",
                "The date in the credential scope does not match the x-amz-date header.",
                debug=[f"scope date: {scope_date}", f"x-amz-date: {amz_date}"],
            )

        provided_hash = headers.get("x-amz-content-sha256")
        actual_hash = hashlib.sha256(body).hexdigest()
        if provided_hash is None:
            payload_hash = actual_hash
        else:
            payload_hash = provided_hash.strip()
            if payload_hash in _STREAMING_PAYLOADS:
                pass  # out of scope: aws-chunked bodies are not supported
            elif payload_hash == "UNSIGNED-PAYLOAD":
                pass
            elif not re.fullmatch(r"[0-9a-fA-F]{64}", payload_hash):
                raise S3Error(
                    400,
                    "InvalidArgument",
                    "x-amz-content-sha256 must be a SHA-256 hex digest or 'UNSIGNED-PAYLOAD'.",
                )
            elif payload_hash.lower() != actual_hash:
                raise S3Error(
                    400,
                    "XAmzContentSHA256Mismatch",
                    "The provided x-amz-content-sha256 does not match the body we received.",
                    debug=[
                        f"header: {payload_hash}",
                        f"actual: {actual_hash}",
                        f"body bytes: {len(body)}",
                    ],
                )
            else:
                payload_hash = payload_hash.lower()

        signed_header_names = match.group("signed_headers")
        signed_headers_list = [name for name in signed_header_names.split(";") if name]

        canonical_header_lines = []
        for name in signed_headers_list:
            raw_value = headers.get(name)
            value = "" if raw_value is None else normalize_header_value(raw_value)
            canonical_header_lines.append(f"{name}:{value}\n")
        canonical_headers = "".join(canonical_header_lines)

        canonical_request = "\n".join(
            [
                method,
                canonical_uri(raw_path),
                canonical_query(raw_query),
                canonical_headers,
                signed_header_names,
                payload_hash,
            ]
        )

        scope = f"{scope_date}/{region}/{service}/aws4_request"
        string_to_sign = "\n".join(
            [
                "AWS4-HMAC-SHA256",
                amz_date,
                scope,
                hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
            ]
        )

        key = signing_key(config.secret, scope_date, region, service)
        expected = hmac.new(key, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
        actual = match.group("signature").lower()
        if not hmac.compare_digest(expected, actual):
            raise S3Error(
                403,
                "SignatureDoesNotMatch",
                "The request signature we calculated does not match the signature you provided.",
                debug=[
                    "canonical request:",
                    *[f"  {line}" for line in canonical_request.split("\n")],
                    f"string to sign: {string_to_sign!r}",
                    f"expected: {expected}",
                    f"actual:   {actual}",
                    f"signed:   {signed_header_names}",
                ],
            )

        return access_key


# --------------------------------------------------------------------------- #
# storage
# --------------------------------------------------------------------------- #


class ObjectStore:
    """Objects on disk, keyed by key. Files are named by the SHA-256 of the key
    so that any key is safe on any filesystem (macOS is case-insensitive), and
    a JSON sidecar records the human-readable key and metadata."""

    def __init__(self, data_dir: str, bucket: str) -> None:
        self.bucket_dir = os.path.join(data_dir, bucket)
        self.objects_dir = os.path.join(self.bucket_dir, "objects")
        self.meta_dir = os.path.join(self.bucket_dir, "meta")
        os.makedirs(self.objects_dir, exist_ok=True)
        os.makedirs(self.meta_dir, exist_ok=True)
        self.index_path = os.path.join(self.bucket_dir, "index.json")
        self._lock = threading.Lock()
        self._items: dict[str, dict] = {}
        self._load()

    # -- disk layout ------------------------------------------------------- #

    @staticmethod
    def _stem(key: str) -> str:
        return hashlib.sha256(key.encode("utf-8")).hexdigest()

    def _object_path(self, key: str) -> str:
        path = os.path.join(self.objects_dir, self._stem(key) + ".bin")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        return path

    def _meta_path(self, key: str) -> str:
        path = os.path.join(self.meta_dir, self._stem(key) + ".json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        return path

    def _write_index(self) -> None:
        document = {
            key: {
                "file": os.path.relpath(self._object_path(key), self.bucket_dir),
                "size": item["size"],
                "etag": item["etag"],
                "contentType": item["contentType"],
                "lastModified": item["lastModified"],
            }
            for key, item in sorted(self._items.items())
        }
        temporary = self.index_path + ".tmp"
        with open(temporary, "w", encoding="utf-8") as handle:
            json.dump(document, handle, indent=2, sort_keys=True, ensure_ascii=False)
            handle.write("\n")
        os.replace(temporary, self.index_path)

    def _load(self) -> None:
        try:
            names = sorted(os.listdir(self.meta_dir))
        except FileNotFoundError:  # pragma: no cover - created above
            return
        for name in names:
            if not name.endswith(".json"):
                continue
            path = os.path.join(self.meta_dir, name)
            try:
                with open(path, "r", encoding="utf-8") as handle:
                    item = json.load(handle)
            except (OSError, ValueError):
                continue
            key = item.get("key")
            if not isinstance(key, str):
                continue
            if not os.path.exists(self._object_path(key)):
                continue
            self._items[key] = item

    # -- operations -------------------------------------------------------- #

    def put(self, key: str, body: bytes, content_type: str) -> dict:
        etag = hashlib.md5(body).hexdigest()  # noqa: S324 - S3 ETags are MD5
        last_modified = time.time()
        item = {
            "key": key,
            "size": len(body),
            "etag": etag,
            "contentType": content_type,
            "lastModified": last_modified,
        }
        with self._lock:
            with open(self._object_path(key), "wb") as handle:
                handle.write(body)
            temporary = self._meta_path(key) + ".tmp"
            with open(temporary, "w", encoding="utf-8") as handle:
                json.dump(item, handle, indent=2, sort_keys=True, ensure_ascii=False)
                handle.write("\n")
            os.replace(temporary, self._meta_path(key))
            self._items[key] = item
            self._write_index()
        return item

    def head(self, key: str) -> dict | None:
        with self._lock:
            item = self._items.get(key)
            return dict(item) if item else None

    def get(self, key: str) -> tuple[dict, bytes] | None:
        with self._lock:
            item = self._items.get(key)
            if item is None:
                return None
            path = self._object_path(key)
        try:
            with open(path, "rb") as handle:
                return dict(item), handle.read()
        except FileNotFoundError:
            return None

    def delete(self, key: str) -> bool:
        with self._lock:
            existed = self._items.pop(key, None) is not None
            for path in (self._object_path(key), self._meta_path(key)):
                try:
                    os.remove(path)
                except FileNotFoundError:
                    pass
            if existed:
                self._write_index()
            return existed

    def keys(self) -> list[str]:
        with self._lock:
            return sorted(self._items)


# --------------------------------------------------------------------------- #
# HTTP handler
# --------------------------------------------------------------------------- #


class MockS3Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "MockS3/1.0"
    sys_version = ""

    # -- plumbing ---------------------------------------------------------- #

    def log_message(self, fmt: str, *args) -> None:  # silence default logging
        pass

    @property
    def config(self) -> Config:
        return self.server.config  # type: ignore[attr-defined]

    @property
    def store(self) -> ObjectStore:
        return self.server.store  # type: ignore[attr-defined]

    def do_GET(self) -> None:
        self._handle("GET")

    def do_PUT(self) -> None:
        self._handle("PUT")

    def do_DELETE(self) -> None:
        self._handle("DELETE")

    def do_HEAD(self) -> None:
        self._handle("HEAD")

    def do_POST(self) -> None:
        self._handle("POST")

    # -- request/response helpers ------------------------------------------ #

    def _read_body(self) -> bytes:
        encoding = (self.headers.get("Transfer-Encoding") or "").lower()
        if "chunked" in encoding:
            return self._read_chunked_body()
        raw_length = self.headers.get("Content-Length")
        if not raw_length:
            return b""
        try:
            length = int(raw_length)
        except ValueError:
            return b""
        if length <= 0:
            return b""
        chunks = []
        remaining = length
        while remaining > 0:
            chunk = self.rfile.read(min(remaining, 1 << 20))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def _read_chunked_body(self) -> bytes:
        chunks = []
        while True:
            line = self.rfile.readline(1024).strip()
            if not line:
                break
            try:
                size = int(line.split(b";", 1)[0], 16)
            except ValueError:
                break
            if size == 0:
                # consume trailers up to the blank line
                while True:
                    trailer = self.rfile.readline(1024)
                    if trailer in (b"\r\n", b"\n", b""):
                        break
                break
            chunks.append(self.rfile.read(size))
            self.rfile.read(2)  # trailing CRLF
        return b"".join(chunks)

    def _send(
        self,
        status: int,
        body: bytes = b"",
        content_type: str | None = None,
        headers: Iterable[tuple[str, str]] | None = None,
        content_length: int | None = None,
    ) -> None:
        self.send_response(status)
        if content_type:
            self.send_header("Content-Type", content_type)
        self.send_header("x-amz-request-id", self._request_id)
        for name, value in headers or ():
            self.send_header(name, value)
        if status != 204:
            self.send_header("Content-Length", str(len(body) if content_length is None else content_length))
        self.end_headers()
        self._status = status
        self._bytes = len(body) if content_length is None else content_length
        if self.command == "HEAD":
            return
        if body:
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):  # pragma: no cover
                pass

    def _send_error_body(self, error: S3Error) -> None:
        body = error.to_xml(self._request_id)
        self._send(
            error.status,
            body,
            content_type="application/xml",
            content_length=0 if self.command == "HEAD" else None,
        )

    def _send_empty(self, status: int, headers: Iterable[tuple[str, str]] | None = None) -> None:
        self._send(status, b"", headers=headers)

    # -- routing ----------------------------------------------------------- #

    def _handle(self, method: str) -> None:
        started = time.monotonic()
        self._request_id = self.server.next_request_id()  # type: ignore[attr-defined]
        self._status = 500
        self._bytes = 0
        self._signature = "skip"
        try:
            body = self._read_body()
            raw_path, _, raw_query = self.path.partition("?")
            if self.config.require_auth:
                try:
                    self.server.verifier.verify(  # type: ignore[attr-defined]
                        method, raw_path, raw_query, self.headers, body
                    )
                    self._signature = "ok"
                except S3Error as error:
                    self._signature = "fail"
                    self._log_debug(error)
                    raise
            bucket, key = self._resolve_target()
            if bucket != self.config.bucket:
                raise S3Error(
                    404,
                    "NoSuchBucket",
                    f"The specified bucket does not exist: {bucket!r}. "
                    f"This mock only serves {self.config.bucket!r}.",
                )
            self._dispatch(method, key, raw_path, raw_query, body)
        except S3Error as error:
            try:
                self._send_error_body(error)
            except (BrokenPipeError, ConnectionResetError):  # pragma: no cover
                self.close_connection = True
                return
        except (BrokenPipeError, ConnectionResetError):  # pragma: no cover
            self.close_connection = True
            return
        except Exception as error:  # pragma: no cover - defensive
            try:
                self._send_error_body(S3Error(500, "InternalError", f"{type(error).__name__}: {error}"))
            except (BrokenPipeError, ConnectionResetError):
                self.close_connection = True
                return
        finally:
            if not self.config.quiet:
                elapsed_ms = (time.monotonic() - started) * 1000
                print(
                    f"{method} {self.path} -> {self._status} {self._bytes}B "
                    f"sig={self._signature} {elapsed_ms:.1f}ms",
                    flush=True,
                )

    def _log_debug(self, error: S3Error) -> None:
        if self.config.quiet or not error.debug:
            return
        print(f"  ! {error.code}: {error.message}", flush=True)
        for line in error.debug:
            print(f"    {line}", flush=True)

    def _resolve_target(self) -> tuple[str, str]:
        raw_path = self.path.partition("?")[0]
        hostname = self._hostname()
        bucket = self.config.bucket.lower()
        if hostname != self.config.host.lower() and hostname.startswith(bucket + "."):
            # virtual-host style: bucket.example.com/key
            return self.config.bucket, unquote(raw_path.lstrip("/"), encoding="utf-8", errors="replace")
        trimmed = raw_path.lstrip("/")
        if not trimmed:
            return "", ""
        if "/" in trimmed:
            raw_bucket, rest = trimmed.split("/", 1)
        else:
            raw_bucket, rest = trimmed, ""
        return (
            unquote(raw_bucket, encoding="utf-8", errors="replace"),
            unquote(rest, encoding="utf-8", errors="replace"),
        )

    def _hostname(self) -> str:
        host = (self.headers.get("Host") or "").strip()
        if host.startswith("["):
            end = host.find("]")
            if end != -1:
                return host[1:end].lower()
        if host.count(":") == 1:
            host = host.split(":", 1)[0]
        return host.lower()

    # -- operations -------------------------------------------------------- #

    def _dispatch(
        self,
        method: str,
        key: str,
        raw_path: str,
        raw_query: str,
        body: bytes,
    ) -> None:
        params = dict(parse_qsl(raw_query, keep_blank_values=True))

        if method == "POST":
            raise S3Error(405, "MethodNotAllowed", "This mock does not implement POST.")

        if not key:
            if method in ("GET", "HEAD"):
                if method == "HEAD":
                    self._send_empty(200)
                    return
                self._list_objects(params)
                return
            raise S3Error(400, "InvalidRequest", f"{method} on a bucket is not supported; include an object key.")

        if method == "PUT":
            self._put_object(key, body)
        elif method == "GET":
            self._get_object(key)
        elif method == "HEAD":
            self._head_object(key)
        elif method == "DELETE":
            self._delete_object(key)
        else:  # pragma: no cover - do_* only routes the five above
            raise S3Error(405, "MethodNotAllowed", f"{method} is not supported.")

    def _put_object(self, key: str, body: bytes) -> None:
        content_type = self.headers.get("Content-Type") or "application/octet-stream"
        item = self.store.put(key, body, content_type)
        self._send_empty(
            200,
            headers=[
                ("ETag", f'"{item["etag"]}"'),
                ("x-amz-content-sha256", hashlib.sha256(body).hexdigest()),
            ],
        )
        # For a write the interesting number is what landed, not the empty
        # response body; keep the log line comparable across methods.
        self._bytes = len(body)

    def _get_object(self, key: str) -> None:
        found = self.store.get(key)
        if found is None:
            raise S3Error(
                404,
                "NoSuchKey",
                f"The specified key does not exist: {key!r}.",
                extra={"Key": key},
            )
        item, body = found
        self._send(
            200,
            body,
            content_type=item["contentType"],
            headers=[
                ("ETag", f'"{item["etag"]}"'),
                ("Last-Modified", _http_date(item["lastModified"])),
                ("Accept-Ranges", "bytes"),
            ],
        )

    def _head_object(self, key: str) -> None:
        item = self.store.head(key)
        if item is None:
            raise S3Error(
                404,
                "NoSuchKey",
                f"The specified key does not exist: {key!r}.",
                extra={"Key": key},
            )
        self._send(
            200,
            b"",
            content_type=item["contentType"],
            headers=[
                ("ETag", f'"{item["etag"]}"'),
                ("Last-Modified", _http_date(item["lastModified"])),
                ("Accept-Ranges", "bytes"),
            ],
            content_length=item["size"],
        )

    def _delete_object(self, key: str) -> None:
        self.store.delete(key)
        self._send_empty(204)

    def _list_objects(self, params: dict[str, str]) -> None:
        prefix = params.get("prefix", "")
        max_keys_raw = params.get("max-keys", "1000")
        try:
            max_keys = int(max_keys_raw)
        except ValueError as error:
            raise S3Error(
                400,
                "InvalidArgument",
                f"max-keys must be an integer, got {max_keys_raw!r}.",
            ) from error
        max_keys = max(0, min(max_keys, 1000))

        token = params.get("continuation-token")
        after: str | None = None
        if token:
            try:
                padded = token.encode("ascii") + b"=" * (-len(token) % 4)
                decoded = base64.b64decode(padded, altchars=b"-_", validate=True).decode("utf-8")
                # Only accept the exact canonical form this server issues, so
                # random base64 noise is reported instead of silently listing.
                if base64.urlsafe_b64encode(decoded.encode("utf-8")).decode("ascii").rstrip("=") != token:
                    raise ValueError("non-canonical token")
                after = decoded
            except Exception as error:  # noqa: BLE001 - any decode failure is a bad token
                raise S3Error(
                    400,
                    "InvalidArgument",
                    "The continuation token is not one this server issued.",
                ) from error

        keys = [key for key in self.store.keys() if key.startswith(prefix)]
        if after is not None:
            keys = [key for key in keys if key > after]

        if max_keys == 0:
            page: list[str] = []
            truncated = False
        else:
            page = keys[:max_keys]
            truncated = len(keys) > max_keys

        next_token = None
        if truncated and page:
            next_token = base64.urlsafe_b64encode(page[-1].encode("utf-8")).decode("ascii").rstrip("=")

        parts = [
            '<?xml version="1.0" encoding="UTF-8"?>\n',
            f'<ListBucketResult xmlns="{XMLNS}">',
            f"<Name>{_xml_text(self.config.bucket)}</Name>",
            f"<Prefix>{_xml_text(prefix)}</Prefix>",
        ]
        if token:
            parts.append(f"<ContinuationToken>{_xml_text(token)}</ContinuationToken>")
        parts.append(f"<KeyCount>{len(page)}</KeyCount>")
        parts.append(f"<MaxKeys>{max_keys}</MaxKeys>")
        parts.append(f"<IsTruncated>{'true' if truncated else 'false'}</IsTruncated>")
        if next_token:
            parts.append(f"<NextContinuationToken>{_xml_text(next_token)}</NextContinuationToken>")

        for key in page:
            item = self.store.head(key)
            if item is None:  # deleted between the snapshot and now
                continue
            parts.append(
                "<Contents>"
                f"<Key>{_xml_text(key)}</Key>"
                f"<LastModified>{_iso8601_millis(item['lastModified'])}</LastModified>"
                f'<ETag>"{_xml_text(item["etag"])}"</ETag>'
                f"<Size>{item['size']}</Size>"
                "<StorageClass>STANDARD</StorageClass>"
                "</Contents>"
            )
        parts.append("</ListBucketResult>\n")

        self._send(200, "".join(parts).encode("utf-8"), content_type="application/xml")


def _iso8601_millis(timestamp: float) -> str:
    moment = datetime.fromtimestamp(timestamp, timezone.utc)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.") + f"{moment.microsecond // 1000:03d}Z"


def _http_date(timestamp: float) -> str:
    return formatdate(timestamp, usegmt=True)


# --------------------------------------------------------------------------- #
# server
# --------------------------------------------------------------------------- #


class MockS3Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, config: Config) -> None:
        self.config = config
        self.store = ObjectStore(config.data_dir, config.bucket)
        self.verifier = SigV4Verifier(config)
        self._request_counter = 0
        self._request_lock = threading.Lock()
        super().__init__((config.host, config.port), MockS3Handler)
        self.config.port = self.server_address[1]

    def next_request_id(self) -> str:
        with self._request_lock:
            self._request_counter += 1
            return f"REQ-{self._request_counter:08d}"


def make_server(config: Config) -> MockS3Server:
    return MockS3Server(config)


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #


def start_in_thread(config: Config) -> tuple[MockS3Server, threading.Thread]:
    """Used by the tests: bind, serve in a daemon thread, return both."""
    server = make_server(config)
    thread = threading.Thread(
        target=server.serve_forever,
        kwargs={"poll_interval": 0.02},
        name="mock-s3",
        daemon=True,
    )
    thread.start()
    return server, thread


def stop_server(server: MockS3Server, thread: threading.Thread | None = None) -> None:
    server.shutdown()
    server.server_close()
    if thread is not None:
        thread.join(timeout=5)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="mock_s3.py",
        description="A small S3-compatible server for integration-testing Backu.",
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9000, help="0 picks a free port")
    parser.add_argument("--bucket", default="backu-test")
    parser.add_argument("--access-key", default="testkey")
    parser.add_argument("--secret", default="testsecret")
    parser.add_argument("--region", default="us-east-1")
    parser.add_argument(
        "--data-dir",
        default="",
        help="where objects and sidecars are written (default: a new temp directory)",
    )
    parser.add_argument("--no-auth", action="store_true", help="accept unsigned requests")
    parser.add_argument("--quiet", action="store_true", help="do not log requests")
    parser.add_argument(
        "--clock-skew",
        type=int,
        default=900,
        metavar="SECONDS",
        help="reject requests further than this from now (default: 900)",
    )
    return parser


def config_from_args(argv: list[str] | None = None) -> Config:
    args = build_parser().parse_args(argv)
    return Config(
        host=args.host,
        port=args.port,
        bucket=args.bucket,
        access_key=args.access_key,
        secret=args.secret,
        region=args.region,
        data_dir=args.data_dir,
        require_auth=not args.no_auth,
        quiet=args.quiet,
        max_skew_seconds=args.clock_skew,
    )


def main(argv: list[str] | None = None) -> int:
    config = config_from_args(argv)
    server = make_server(config)
    # Let SIGTERM unwind through the KeyboardInterrupt path below so the socket
    # is closed properly when a test harness or supervisor stops the process.
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, signal.default_int_handler)
    host, port = server.server_address[:2]
    print(f"Mock S3 listening on http://{host}:{port}", flush=True)
    print(
        f"  bucket={config.bucket} region={config.region} "
        f"auth={'on' if config.require_auth else 'off'} path-style=true",
        flush=True,
    )
    if config.require_auth:
        print(f"  access key={config.access_key}", flush=True)
    print(f"  data dir={config.data_dir}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
