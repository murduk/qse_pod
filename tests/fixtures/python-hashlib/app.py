"""Test fixture: deliberately uses weak cryptography so QSE has findings."""
import hashlib


def weak_digest(data: bytes) -> str:
    return hashlib.md5(data).hexdigest()


def legacy_digest(data: bytes) -> str:
    return hashlib.sha1(data).hexdigest()


if __name__ == "__main__":
    print(weak_digest(b"hello"), legacy_digest(b"hello"))
