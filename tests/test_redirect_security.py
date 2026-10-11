import importlib.util
import stat
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from importlib.machinery import SourceFileLoader
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen


PROJECT = Path(__file__).resolve().parents[1]
loader = SourceFileLoader("jellyfin_cinema_test", str(PROJECT / "bin" / "jellyfin-cinema"))
spec = importlib.util.spec_from_loader(loader.name, loader)
helper_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper_module)
API = helper_module.API
JellyfinStreamProxy = helper_module.JellyfinStreamProxy
TOKEN = "LOCAL_TEST_SENTINEL"
redirect_target = ""
received_authorization = []
received_ranges = []
received_stream_authorization = []
received_local_redirect_authorization = []


class TargetHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        received_authorization.append(self.headers.get("Authorization", ""))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *args):
        pass


class SourceHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/ok":
            received_local_redirect_authorization.append(self.headers.get("Authorization", ""))
        if self.path == "/redirect-external":
            self.send_response(302)
            self.send_header("Location", redirect_target)
            self.end_headers()
            return
        if self.path == "/stream-redirect":
            received_stream_authorization.append(self.headers.get("Authorization", ""))
            self.send_response(302)
            self.send_header("Location", redirect_target)
            self.end_headers()
            return
        if self.path == "/redirect-local":
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/ok")
            self.end_headers()
            return
        if self.path == "/stream":
            received_stream_authorization.append(self.headers.get("Authorization", ""))
            received_ranges.append(self.headers.get("Range", ""))
            self.send_response(206 if self.headers.get("Range") else 200)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Accept-Ranges", "bytes")
            if self.headers.get("Range"):
                self.send_header("Content-Range", "bytes 2-5/10")
                self.send_header("Content-Length", "4")
                self.end_headers()
                self.wfile.write(b"2345")
            else:
                self.send_header("Content-Length", "10")
                self.end_headers()
                self.wfile.write(b"0123456789")
            return
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *args):
        pass


class RedirectSecurityTests(unittest.TestCase):
    def setUp(self):
        global redirect_target, received_authorization, received_ranges, received_stream_authorization, received_local_redirect_authorization
        received_authorization = []
        received_ranges = []
        received_stream_authorization = []
        received_local_redirect_authorization = []
        self.target = ThreadingHTTPServer(("127.0.0.1", 0), TargetHandler)
        self.target_thread = threading.Thread(target=self.target.serve_forever, daemon=True)
        self.target_thread.start()
        redirect_target = f"http://127.0.0.1:{self.target.server_port}/capture"

        self.source = ThreadingHTTPServer(("127.0.0.1", 0), SourceHandler)
        self.source_thread = threading.Thread(target=self.source.serve_forever, daemon=True)
        self.source_thread.start()
        self.api = API({"server": f"http://127.0.0.1:{self.source.server_port}", "token": TOKEN})

    def tearDown(self):
        self.source.shutdown()
        self.target.shutdown()
        self.source.server_close()
        self.target.server_close()

    def test_refuses_cross_origin_redirect_before_sending_token(self):
        with self.assertRaisesRegex(ValueError, "different origin"):
            self.api.request("/redirect-external")
        self.assertEqual(received_authorization, [])

    def test_allows_redirect_within_configured_origin(self):
        self.assertEqual(self.api.request("/redirect-local"), {})
        self.assertTrue(any(TOKEN in value for value in received_local_redirect_authorization))

    def test_playback_proxy_keeps_token_out_of_mpv_and_preserves_range(self):
        proxy = JellyfinStreamProxy(f"http://127.0.0.1:{self.source.server_port}/stream", TOKEN)
        try:
            local_url = proxy.start()
            self.assertNotIn(TOKEN, local_url)
            with urlopen(Request(local_url, headers={"Range": "bytes=2-5"}), timeout=5) as response:
                self.assertEqual(response.status, 206)
                self.assertEqual(response.read(), b"2345")
            self.assertEqual(received_ranges, ["bytes=2-5"])
            self.assertEqual(received_stream_authorization, ["MediaBrowser Token=" + TOKEN])
        finally:
            proxy.close()

    def test_playback_proxy_blocks_cross_origin_redirect(self):
        proxy = JellyfinStreamProxy(f"http://127.0.0.1:{self.source.server_port}/stream-redirect", TOKEN)
        try:
            local_url = proxy.start()
            with self.assertRaises(HTTPError) as response:
                urlopen(local_url, timeout=5)
            self.assertEqual(response.exception.code, 502)
            response.exception.close()
            self.assertEqual(received_stream_authorization, ["MediaBrowser Token=" + TOKEN])
            self.assertEqual(received_authorization, [])
        finally:
            proxy.close()

    def test_saved_session_and_parent_directory_are_private(self):
        previous_config = helper_module.CONFIG
        try:
            with tempfile.TemporaryDirectory() as temp:
                helper_module.CONFIG = Path(temp) / "private" / "config.json"
                helper_module.save({"token": TOKEN})
                config = helper_module.CONFIG
                self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o600)
                self.assertEqual(stat.S_IMODE(config.parent.stat().st_mode), 0o700)
                self.assertEqual(config.read_text(), '{"token": "LOCAL_TEST_SENTINEL"}')
                config.chmod(0o644)
                self.assertEqual(helper_module.load(), {"token": TOKEN})
                self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o600)
        finally:
            helper_module.CONFIG = previous_config


if __name__ == "__main__":
    unittest.main()
