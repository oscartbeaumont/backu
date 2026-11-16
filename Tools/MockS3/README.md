# Mock S3

A small, Python-standard-library-only S3 server for integration-testing Backu's
`S3Client` without touching real cloud storage. It verifies **real AWS
Signature V4**, so a broken signer in the app fails here exactly like it would
fail against S3.

Implemented: `GET` object, `GET ?list-type=2` (ListObjectsV2), `PUT`, `DELETE`,
`HEAD`, path-style and virtual-host addressing, and XML error responses.

## Run it

```sh
python3 Tools/MockS3/mock_s3.py --data-dir /tmp/backu-s3
```

Defaults: `127.0.0.1:9000`, bucket `backu-test`, access key `testkey`, secret
`testsecret`, region `us-east-1`, auth on. Options:

| flag | meaning |
| --- | --- |
| `--host`, `--port` | listen address; `--port 0` picks a free port and prints it |
| `--bucket` | the one bucket that exists (any other name returns `NoSuchBucket`) |
| `--access-key`, `--secret`, `--region` | credentials the server accepts |
| `--data-dir` | where objects and sidecars are written (default: a new temp dir) |
| `--no-auth` | skip signature checks (handy for poking at it with curl) |
| `--clock-skew` | reject requests skewed more than N seconds (default `900`) |
| `--quiet` | no per-request log lines |

Each request logs one line:

```
PUT /backu-test/Backu/photo.jpg -> 200 182344B sig=ok 1.2ms
```

On a signature failure the canonical request, string to sign, and the expected
and actual signatures are printed, so a client bug is easy to locate.

## Point the app at it

In Backu, add a server with:

- endpoint `http://127.0.0.1:9000`
- bucket `backu-test`
- region `us-east-1`
- access key `testkey`
- secret `testsecret`
- path-style addressing **on** (the mock also accepts virtual-host style if the
  host is `backu-test.<host>`)

Tap verify: it should report list/read/write all working. Put the secret in the
keychain as the app normally does.

## Inspecting what was uploaded

Objects live under `<data-dir>/backu-test/`:

```
backu-test/
  index.json                      # key -> {file, size, etag, contentType, lastModified}
  objects/<sha256-of-key>.bin     # the raw bytes
  meta/<sha256-of-key>.json       # sidecar with the real key and metadata
```

Files are named by the hash of the key so any key (unicode, spaces, `%`, even
keys that differ only by case on a case-insensitive macOS filesystem) round-trips
safely. `index.json` gives you the human-readable mapping:

```sh
cat /tmp/backu-s3/backu-test/index.json
xxd /tmp/backu-s3/backu-test/objects/*.bin | head
```

## Tests

```sh
python3 Tools/MockS3/test_mock_s3.py
```

or

```sh
python3 -m unittest discover -s Tools/MockS3 -p 'test_*.py'
```

The suite starts servers on free ports in a thread and uses a **separate**,
hand-written SigV4 signer (it does not import the server's verifier), covering
put/get/head/list with prefix, pagination with `max-keys=1`, delete, rejection
of bad signatures, access keys, and skewed clocks, plus keys with spaces and
unicode.

## Limits

One bucket, no ACLs, no multipart, no versioning, no `aws-chunked` bodies. It is
a test fixture, not an S3 implementation.
