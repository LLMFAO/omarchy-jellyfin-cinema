import io
import importlib.util
import tempfile
import unittest
from contextlib import redirect_stdout
from importlib.machinery import SourceFileLoader
from pathlib import Path
from unittest.mock import patch


PROJECT = Path(__file__).resolve().parents[1]
loader = SourceFileLoader("jellyfin_cinema_lifecycle_test", str(PROJECT / "bin" / "jellyfin-cinema"))
spec = importlib.util.spec_from_loader(loader.name, loader)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class PlaybackLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.old_config = helper.CONFIG
        self.old_cache = helper.CACHE
        helper.CONFIG = Path(self.temp.name) / "private" / "config.json"
        helper.CACHE = Path(self.temp.name) / "cache" / "posters"

    def tearDown(self):
        helper.CONFIG = self.old_config
        helper.CACHE = self.old_cache
        self.temp.cleanup()

    def test_delayed_player_rejects_account_replaced_before_lock(self):
        current = {"server": "https://jellyfin.example", "user": "account-b", "token": "token-b"}
        previous = {"server": "https://jellyfin.example", "user": "account-a", "token": "token-a"}
        helper.save(current)
        launch_id = "a" * 32

        with patch.object(helper, "windows", return_value=[]), patch.object(helper, "_play_locked") as start:
            with self.assertRaisesRegex(ValueError, "account changed"):
                helper.play(previous, "movie-id", launch_id)

        start.assert_not_called()

    def test_http_login_requires_an_explicit_transport_acknowledgment(self):
        data = {"server": "http://jellyfin.example", "username": "paul", "password": "test-password"}
        with patch.object(helper.sys, "argv", ["jellyfin-cinema", "login"]), patch.object(helper.sys, "stdin", io.StringIO(helper.json.dumps(data))):
            with self.assertRaisesRegex(ValueError, "HTTP is not encrypted"):
                helper.main()
        self.assertFalse(helper.load().get("token"))

    def test_acknowledged_http_login_reaches_authentication(self):
        data = {"server": "http://jellyfin.example", "username": "paul", "password": "test-password", "allowInsecureHttp": True}

        class AuthAPI:
            def __init__(self, cfg):
                self.cfg = cfg

            def request(self, path, payload):
                self.asserted = (path, payload)
                return {"AccessToken": "private-test-token", "User": {"Id": "account-a", "Name": "paul"}}

        with patch.object(helper.sys, "argv", ["jellyfin-cinema", "login"]), patch.object(helper.sys, "stdin", io.StringIO(helper.json.dumps(data))), patch.object(helper, "API", AuthAPI), patch("builtins.print"):
            helper.main()

        self.assertEqual(helper.load()["server"], "http://jellyfin.example")
        self.assertEqual(helper.load()["user"], "account-a")

    def test_player_uses_saved_account_after_acquiring_lock(self):
        current = {"server": "https://jellyfin.example", "user": "account-a", "token": "token-a"}
        helper.save(current)
        launch_id = "b" * 32

        with patch.object(helper, "windows", return_value=[]), patch.object(helper, "_play_locked", return_value="started") as start:
            result = helper.play(dict(current), "movie-id", launch_id)

        self.assertEqual(result, "started")
        self.assertEqual(start.call_args.args[0], current)

    def test_lock_is_machine_wide_across_account_changes(self):
        first = {"server": "https://one.example", "user": "account-a"}
        second = {"server": "https://two.example", "user": "account-b"}
        fd1 = helper.playback_lock(first)
        fd2 = helper.playback_lock(second)
        try:
            helper.fcntl.flock(fd1, helper.fcntl.LOCK_EX | helper.fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                helper.fcntl.flock(fd2, helper.fcntl.LOCK_EX | helper.fcntl.LOCK_NB)
        finally:
            helper.fcntl.flock(fd1, helper.fcntl.LOCK_UN)
            helper.os.close(fd1)
            helper.os.close(fd2)

    def test_logout_retains_token_if_server_revocation_fails(self):
        config = {"server": "https://jellyfin.example", "user": "account-a", "token": "test-token"}
        helper.save(config)
        raised = []

        class FailedLogout:
            def __init__(self, cfg):
                pass

            def request(self, path, data=None):
                error = helper.HTTPError("https://jellyfin.example/Sessions/Logout", 500, "failed", None, None)
                raised.append(error)
                raise error

        output = Path(self.temp.name) / "stdout.txt"
        with patch.object(helper, "windows", return_value=[]), patch.object(helper, "API", FailedLogout), patch.object(helper.sys, "argv", ["jellyfin-cinema", "logout"]):
            with output.open("w") as stream, redirect_stdout(stream):
                with self.assertRaises(helper.HTTPError):
                    helper.main()
        raised[0].close()

        self.assertEqual(helper.load(), config)

    def test_logout_clears_expired_token_and_reports_local_clear(self):
        config = {"server": "https://jellyfin.example", "user": "account-a", "token": "test-token"}
        helper.save(config)
        raised = []

        class ExpiredLogout:
            def __init__(self, cfg):
                pass

            def request(self, path, data=None):
                error = helper.HTTPError("https://jellyfin.example/Sessions/Logout", 401, "expired", None, None)
                raised.append(error)
                raise error

        output = Path(self.temp.name) / "stdout.txt"
        with patch.object(helper, "windows", return_value=[]), patch.object(helper, "API", ExpiredLogout), patch.object(helper.sys, "argv", ["jellyfin-cinema", "logout"]):
            with output.open("w") as stream, redirect_stdout(stream):
                helper.main()
        raised[0].close()

        self.assertNotIn("token", helper.load())
        self.assertIn("Local login cleared", output.read_text())

    def test_logout_holds_offline_transfer_lock_before_revoking_account(self):
        config = {"server": "https://jellyfin.example", "user": "account-a", "token": "test-token"}
        helper.save(config)
        lock = helper.acquire_download_lock()
        self.assertIsNotNone(lock)
        try:
            with patch.object(helper.sys, "argv", ["jellyfin-cinema", "logout"]), patch.object(helper, "API") as api:
                with self.assertRaisesRegex(ValueError, "active download"):
                    helper.main()
            api.assert_not_called()
            self.assertEqual(helper.load(), config)
        finally:
            helper.fcntl.flock(lock, helper.fcntl.LOCK_UN)
            helper.os.close(lock)

    def test_sessions_are_filtered_to_the_connected_user(self):
        cfg = {"server": "https://jellyfin.example", "user": "account-a", "token": "test-token"}
        sessions = [
            {"UserId": "account-a", "DeviceName": "TV", "NowPlayingItem": {"Id": "movie-a", "Name": "Mine", "MediaType": "Video"}},
            {"UserId": "account-b", "DeviceName": "Other TV", "NowPlayingItem": {"Id": "movie-b", "Name": "Theirs", "MediaType": "Video"}},
            {"DeviceName": "Unknown owner", "NowPlayingItem": {"Id": "movie-c", "Name": "Unknown", "MediaType": "Video"}},
        ]

        class SessionAPI:
            def __init__(self, cfg):
                pass

            def request(self, path):
                self_path = path
                if self_path != "/Sessions":
                    raise AssertionError("Unexpected API request")
                return sessions

        with patch.object(helper, "API", SessionAPI):
            result = helper.active_sessions(cfg)

        self.assertEqual([item["title"] for item in result], ["Mine"])

    def test_local_playback_status_survives_session_request_failure(self):
        config = {"server": "https://jellyfin.example", "user": "account-a", "token": "test-token"}
        helper.save(config)
        helper.store_player_state(config, {"pid": 1001, "title": "Local movie", "poster": "", "subtitleStyle": "terminal", "subtitleSize": 34})
        fd = helper.playback_lock(config)
        helper.fcntl.flock(fd, helper.fcntl.LOCK_EX | helper.fcntl.LOCK_NB)

        class OfflineAPI:
            def __init__(self, cfg):
                pass

            def request(self, path):
                raise helper.URLError("offline")

        try:
            with patch.object(helper, "API", OfflineAPI):
                result = helper.playback_status(config)
        finally:
            helper.fcntl.flock(fd, helper.fcntl.LOCK_UN)
            helper.os.close(fd)

        self.assertTrue(result["localPlaying"])
        self.assertEqual(result["sessions"][0]["title"], "Local movie")
        self.assertTrue(result["statusError"])

    def test_orphaned_launch_state_expires_and_is_removed(self):
        launch_id = "c" * 32
        helper.save_launch_state(launch_id, {"status": "starting", "message": "Starting"})
        path = helper.launch_state_path(launch_id)
        state = helper.json.loads(path.read_text())
        state["updatedAt"] = 1
        path.write_text(helper.json.dumps(state))

        result = helper.read_launch_state(launch_id)

        self.assertEqual(result["status"], "failed")
        self.assertFalse(path.exists())


if __name__ == "__main__":
    unittest.main()
