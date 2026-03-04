import json
import unittest
from unittest.mock import patch

from openclaw_zig_rpc_client import OpenClawClient, OpenClawRpcError


class _FakeResponse:
    def __init__(self, status: int, payload: dict):
        self.status = status
        self._raw = json.dumps(payload).encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def read(self):
        return self._raw


class OpenClawClientTests(unittest.TestCase):
    def test_rpc_url_trims_base_slash(self):
        client = OpenClawClient(base_url="http://127.0.0.1:8080/")
        self.assertEqual("http://127.0.0.1:8080/rpc", client.rpc_url())

    def test_rpc_requires_non_empty_method(self):
        client = OpenClawClient()
        with self.assertRaises(OpenClawRpcError):
            client.rpc("")

    @patch("urllib.request.urlopen")
    def test_rpc_success(self, mock_urlopen):
        mock_urlopen.return_value = _FakeResponse(200, {"result": {"ok": True}})
        client = OpenClawClient()
        result = client.rpc("health", {})
        self.assertEqual({"ok": True}, result)

    @patch("urllib.request.urlopen")
    def test_rpc_error_frame_raises(self, mock_urlopen):
        mock_urlopen.return_value = _FakeResponse(200, {"error": {"message": "bad"}})
        client = OpenClawClient()
        with self.assertRaises(OpenClawRpcError):
            client.rpc("status", {})


if __name__ == "__main__":
    unittest.main()
