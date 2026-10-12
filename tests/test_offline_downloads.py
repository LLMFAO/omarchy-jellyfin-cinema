import importlib.util
import json
import os
import socket
import stat
import tempfile
import threading
from email.message import Message
from types import SimpleNamespace
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from importlib.machinery import SourceFileLoader
from pathlib import Path
from unittest.mock import patch


PROJECT = Path(__file__).resolve().parents[1]
loader = SourceFileLoader("jellyfin_cinema_offline_test", str(PROJECT / "bin" / "jellyfin-cinema"))
spec = importlib.util.spec_from_loader(loader.name, loader)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)

MOVIE = b"0123456789"
TOKEN = "OFFLINE_TEST_SECRET"


class DownloadHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/Items/movie-1/Images/Primary?"):
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", "4")
            self.end_headers()
            self.wfile.write(b"\xff\xd8\xff\xd9")
            return
        if self.path.startswith("/Items/movie-1?"):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({
                "Id": "movie-1", "Name": "Test: Movie/../", "ProductionYear": 2024,
                "RunTimeTicks": 9000000000, "ImageTags": {"Primary": "primary-tag"},
                "UserData": {"PlaybackPositionTicks": 70000000}
            }).encode())
            return
        if self.path != "/Items/movie-1/Download":
            self.send_error(404)
            return
        self.server.auth_headers.append(self.headers.get("Authorization", ""))
        self.server.range_headers.append(self.headers.get("Range"))
        if self.server.mode == "forbidden":
            self.send_response(403)
            self.end_headers()
            return
        if self.server.mode == "resume" and len(self.server.range_headers) == 1:
            self.send_response(200)
            self.send_header("Content-Length", str(len(MOVIE)))
            self.send_header("ETag", '"rev-1"')
            self.send_header("Content-Type", "video/x-matroska")
            self.end_headers()
            self.wfile.write(MOVIE[:4])
            self.wfile.flush()
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.connection.close()
            return
        if self.headers.get("Range"):
            start = int(self.headers["Range"].split("=", 1)[1].split("-", 1)[0])
            body = MOVIE[start:]
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{len(MOVIE)-1}/{len(MOVIE)}")
        else:
            body = MOVIE
            self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("ETag", '"rev-1"')
        self.send_header("Content-Disposition", 'attachment; filename="../../Movie.mkv"')
        self.send_header("Content-Type", "video/x-matroska")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class OfflineDownloadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.old_config, self.old_cache, self.old_default = helper.CONFIG, helper.CACHE, helper.DOWNLOAD_DEFAULT
        helper.CONFIG = Path(self.temp.name) / "private" / "config.json"
        helper.CACHE = Path(self.temp.name) / "cache" / "posters"
        helper.DOWNLOAD_DEFAULT = Path(self.temp.name) / "Downloads" / "Jellyfin Cinema"
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), DownloadHandler)
        self.server.mode = "normal"
        self.server.auth_headers = []
        self.server.range_headers = []
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.cfg = {"server": f"http://127.0.0.1:{self.server.server_port}", "user": "user-id", "username": "test", "token": TOKEN}
        helper.save(self.cfg)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        helper.CONFIG, helper.CACHE, helper.DOWNLOAD_DEFAULT = self.old_config, self.old_cache, self.old_default
        self.temp.cleanup()

    def test_download_streams_to_private_generated_file_and_index_has_no_credentials(self):
        result = helper.download_movie(self.cfg, "movie-1")
        index_path = helper.index_path()
        index = json.loads(index_path.read_text())
        entry = index["entries"][0]
        movie = helper.safe_entry_file(entry)

        self.assertEqual(movie.read_bytes(), MOVIE)
        self.assertEqual(stat.S_IMODE(movie.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(movie.parent.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(index_path.stat().st_mode), 0o600)
        self.assertEqual(entry["positionTicks"], 70000000)
        self.assertTrue(movie.name.startswith("test-movie-"))
        self.assertNotIn(TOKEN, index_path.read_text())
        self.assertNotIn(self.cfg["server"], index_path.read_text())
        self.assertIn("Token=\"" + TOKEN + "\"", self.server.auth_headers[0])
        self.assertEqual(result["key"], entry["key"])
        self.assertEqual(helper.offline_list()["items"][0]["name"], "Test: Movie/../")

    def test_download_permission_denial_never_commits_a_file(self):
        self.server.mode = "forbidden"
        with self.assertRaisesRegex(ValueError, "download.*permission"):
            helper.download_movie(self.cfg, "movie-1")
        self.assertFalse(helper.index_path().exists())
        self.assertFalse(list(helper.DOWNLOAD_DEFAULT.rglob("*.mkv")))

    def test_untrusted_non_media_filename_extension_uses_safe_container_fallback(self):
        headers = Message()
        headers["Content-Disposition"] = 'attachment; filename="malicious.desktop"'
        headers["Content-Type"] = "application/x-desktop"

        self.assertEqual(helper.response_extension(SimpleNamespace(headers=headers)), "mkv")

    def test_offline_refresh_cannot_prune_entry_during_atomic_download_commit(self):
        rename_started = threading.Event()
        allow_rename = threading.Event()
        prune_lock_attempted = threading.Event()
        listing_done = threading.Event()
        download_errors = []
        listing_results = []
        real_replace = helper.os.replace
        real_index_lock = helper.offline_index_lock

        def pause_final_rename(source, destination):
            if Path(source).suffix == ".part":
                rename_started.set()
                if not allow_rename.wait(5):
                    raise TimeoutError("test did not release the final download rename")
            return real_replace(source, destination)

        def observe_listing_lock():
            if threading.current_thread().name == "offline-list-refresh":
                prune_lock_attempted.set()
            return real_index_lock()

        def download():
            try:
                helper.download_movie(self.cfg, "movie-1")
            except Exception as exc:
                download_errors.append(exc)

        def refresh():
            try:
                listing_results.append(helper.offline_list())
            except Exception as exc:
                download_errors.append(exc)
            finally:
                listing_done.set()

        with patch.object(helper.os, "replace", pause_final_rename), patch.object(helper, "offline_index_lock", observe_listing_lock):
            download_thread = threading.Thread(target=download, name="offline-download")
            download_thread.start()
            self.assertTrue(rename_started.wait(5), "download never reached its final rename")
            listing_thread = threading.Thread(target=refresh, name="offline-list-refresh")
            listing_thread.start()
            self.assertTrue(prune_lock_attempted.wait(5), "offline refresh never reached the index lock")
            self.assertFalse(listing_done.wait(0.05), "offline refresh passed the commit lock and pruned the entry")
            allow_rename.set()
            download_thread.join(5)
            listing_thread.join(5)

        self.assertFalse(download_thread.is_alive())
        self.assertFalse(listing_thread.is_alive())
        self.assertEqual(download_errors, [])
        self.assertEqual(len(listing_results[0]["items"]), 1)
        self.assertEqual(len(helper.offline_index()["entries"]), 1)

    def test_interrupted_transfer_resumes_only_from_matching_range_and_validator(self):
        self.server.mode = "resume"
        with self.assertRaisesRegex(ValueError, "ended early"):
            helper.download_movie(self.cfg, "movie-1")
        state = json.loads(helper.job_path().read_text())
        part = helper.account_folder(state["accountKey"]) / state["partFilename"]
        self.assertEqual(part.read_bytes(), MOVIE[:4])
        stale = {
            "key": state["key"], "accountKey": state["accountKey"], "itemId": "movie-1",
            "title": "Old incomplete entry", "filename": "old-movie-1234567890.mkv", "bytes": 10
        }
        helper.save_private_json(helper.index_path(), {"version": 1, "entries": [stale]})

        self.server.mode = "normal"
        helper.download_movie(self.cfg, "movie-1")
        self.assertEqual(self.server.range_headers, [None, "bytes=4-"])
        entry = helper.offline_index()["entries"][0]
        self.assertEqual(helper.safe_entry_file(entry).read_bytes(), MOVIE)

    def test_stale_job_after_atomic_rename_is_reconciled_as_complete(self):
        helper.download_movie(self.cfg, "movie-1")
        job = json.loads(helper.job_path().read_text())
        job["status"] = "running"
        helper.save_download_job(job)

        result = helper.offline_list()

        self.assertEqual(len(result["items"]), 1)
        self.assertFalse(result["job"])
        self.assertEqual(json.loads(helper.job_path().read_text())["status"], "complete")

    def test_missing_external_file_is_pruned_and_folder_can_change(self):
        helper.download_movie(self.cfg, "movie-1")
        entry = helper.offline_index()["entries"][0]
        helper.safe_entry_file(entry).unlink()

        self.assertEqual(helper.offline_list()["items"], [])
        new_folder = Path(self.temp.name) / "Travel Media"
        result = helper.set_download_directory(str(new_folder))

        self.assertEqual(result["directory"], str(new_folder))
        self.assertEqual(helper.offline_index()["entries"], [])

    def test_cancel_removes_interrupted_partial_but_keeps_completed_downloads(self):
        helper.configured_download_root(create=True)
        account = helper.account_key(self.cfg)
        folder = helper.account_folder(account, create=True)
        part_name = "a" * 64 + ".part"
        partial = folder / part_name
        partial.write_bytes(b"partial")
        helper.save_download_job({"status": "interrupted", "accountKey": account, "itemId": "movie-1", "partFilename": part_name, "bytes": 7})

        result = helper.download_cancel()

        self.assertIn("removed", result["message"])
        self.assertFalse(partial.exists())
        self.assertEqual(json.loads(helper.job_path().read_text())["status"], "cancelled")

    def test_cancel_signals_an_active_transfer_without_waiting_for_its_lock(self):
        account = helper.account_key(self.cfg)
        helper.save_download_job({"status": "running", "accountKey": account, "itemId": "movie-1"})
        lock = helper.os.open(helper.download_lock_path(), helper.os.O_CREAT | helper.os.O_RDWR, 0o600)
        helper.fcntl.flock(lock, helper.fcntl.LOCK_EX | helper.fcntl.LOCK_NB)
        try:
            result = helper.download_cancel()
            self.assertTrue(result["cancelRequested"])
            self.assertTrue(helper.cancellation_requested(account, "movie-1"))
        finally:
            helper.fcntl.flock(lock, helper.fcntl.LOCK_UN)
            helper.os.close(lock)

    def test_preflight_space_check_and_hardlink_guard_prevent_unsafe_writes(self):
        account = helper.account_key(self.cfg)
        folder = helper.account_folder(account, create=True)
        part_name = __import__("hashlib").sha256((account + "\0movie-1").encode()).hexdigest() + ".part"
        part = folder / part_name
        outside = Path(self.temp.name) / "outside.part"
        outside.write_bytes(b"preserve")
        os.link(outside, part)
        helper.save_download_job({"status": "interrupted", "accountKey": account, "itemId": "movie-1", "partFilename": part_name, "etag": '"rev-1"'})
        with self.assertRaisesRegex(ValueError, "unsafe partial"):
            helper.download_movie(self.cfg, "movie-1")
        self.assertEqual(outside.read_bytes(), b"preserve")
        part.unlink()

        with patch.object(helper.shutil, "disk_usage", return_value=SimpleNamespace(free=1)):
            with self.assertRaisesRegex(ValueError, "not enough free disk"):
                helper.download_movie(self.cfg, "movie-1")
        self.assertEqual(outside.read_bytes(), b"preserve")
        self.assertFalse(list(helper.DOWNLOAD_DEFAULT.rglob("*.mkv")))

    def test_signout_preserves_download_and_explicit_delete_removes_only_indexed_file(self):
        helper.download_movie(self.cfg, "movie-1")
        entry = helper.offline_index()["entries"][0]
        movie = helper.safe_entry_file(entry)
        helper.save({"server": ""})
        self.assertTrue(movie.exists())
        self.assertEqual(len(helper.offline_list()["items"]), 1)

        result = helper.delete_offline_item(entry["key"])

        self.assertIn("deleted", result["message"])
        self.assertFalse(movie.exists())
        self.assertEqual(helper.offline_index()["entries"], [])

    def test_signed_in_offline_list_is_scoped_but_signed_out_view_keeps_all_files(self):
        helper.download_movie(self.cfg, "movie-1")
        other_account = dict(self.cfg, user="another-user")
        helper.save(other_account)
        helper.download_movie(other_account, "movie-1")

        self.assertEqual(len(helper.offline_list()["items"]), 1)
        self.assertFalse(helper.offline_list()["allAccounts"])
        helper.save({"server": self.cfg["server"]})
        offline = helper.offline_list()
        self.assertEqual(len(offline["items"]), 2)
        self.assertTrue(offline["allAccounts"])

    def test_keep_server_resume_choice_updates_local_position_only(self):
        helper.download_movie(self.cfg, "movie-1")
        entry = helper.offline_index()["entries"][0]
        result = helper.offline_progress_keep_server(self.cfg, entry["key"], 30000000)

        self.assertEqual(result["positionTicks"], 30000000)
        self.assertEqual(helper.offline_index()["entries"][0]["positionTicks"], 30000000)
        self.assertEqual(self.server.range_headers, [None])

    def test_download_folder_cannot_change_while_transfer_owns_global_lock(self):
        lock = helper.acquire_download_lock()
        self.assertIsNotNone(lock)
        try:
            with self.assertRaisesRegex(ValueError, "active download"):
                helper.set_download_directory(str(Path(self.temp.name) / "Other Folder"))
        finally:
            helper.fcntl.flock(lock, helper.fcntl.LOCK_UN)
            helper.os.close(lock)

    def test_offline_delete_refuses_active_player_and_symlinked_file(self):
        helper.download_movie(self.cfg, "movie-1")
        entry = helper.offline_index()["entries"][0]
        lock = helper.playback_lock(self.cfg)
        helper.fcntl.flock(lock, helper.fcntl.LOCK_EX | helper.fcntl.LOCK_NB)
        helper.store_player_state(self.cfg, {"pid": 123, "offlineKey": entry["key"]})
        try:
            with self.assertRaisesRegex(ValueError, "Stop this movie"):
                helper.delete_offline_item(entry["key"])
        finally:
            helper.fcntl.flock(lock, helper.fcntl.LOCK_UN)
            helper.os.close(lock)
        movie = helper.safe_entry_file(entry)
        target = Path(self.temp.name) / "outside.mkv"
        target.write_bytes(b"outside")
        movie.unlink()
        movie.symlink_to(target)
        with self.assertRaisesRegex(ValueError, "symbolic|unsafe"):
            helper.delete_offline_item(entry["key"])
        self.assertEqual(target.read_bytes(), b"outside")

    def test_sync_requires_an_explicit_choice_and_rechecks_server_position(self):
        helper.download_movie(self.cfg, "movie-1")
        entry = helper.offline_index()["entries"][0]
        calls = []
        server_position = 90000000

        class SyncAPI:
            def __init__(self, cfg):
                pass

            def request(self, path, data=None):
                nonlocal server_position
                calls.append((path, data))
                if data is None:
                    return {"UserData": {"PlaybackPositionTicks": server_position}}
                server_position = data["PlaybackPositionTicks"]
                return {}

        with patch.object(helper, "API", SyncAPI):
            preview = helper.offline_progress_preview(self.cfg, entry["key"])
            self.assertEqual(preview["localTicks"], 70000000)
            self.assertEqual(preview["serverTicks"], server_position)
            server_position = 100000000
            with self.assertRaisesRegex(ValueError, "changed since comparison"):
                helper.offline_progress_sync(self.cfg, entry["key"], preview["serverTicks"])
            self.assertFalse(any(data is not None for _, data in calls))
            result = helper.offline_progress_sync(self.cfg, entry["key"], server_position)

        self.assertEqual(result["positionTicks"], 70000000)
        self.assertEqual(server_position, 70000000)
        self.assertEqual(calls[-1][0], "/UserItems/movie-1/UserData")

    def test_artwork_cache_pruning_removes_oldest_files_only(self):
        account_one = helper.CACHE / ("a" * 24)
        account_two = helper.CACHE / ("b" * 24)
        account_one.mkdir(parents=True)
        account_two.mkdir(parents=True)
        old = account_one / "old.jpg"
        middle = account_one / "middle.jpg"
        latest = account_two / "latest.jpg"
        for image in (old, middle, latest): image.write_bytes(b"1234")
        os.utime(old, (1, 1)); os.utime(middle, (2, 2)); os.utime(latest, (3, 3))
        with patch.object(helper, "ART_CACHE_MAX_BYTES", 8):
            helper.prune_artwork_cache()

        self.assertFalse(old.exists())
        self.assertTrue(middle.exists())
        self.assertTrue(latest.exists())


if __name__ == "__main__":
    unittest.main()
