"""Offline checks for the HTTPS config downloads embedded in game-setup.sh."""
import io
import json
from pathlib import Path
import re
import shutil
import ssl
import subprocess
import tempfile
import threading
import unittest
import urllib.request
from unittest.mock import Mock, patch


SCRIPT = (Path(__file__).resolve().parents[1] / "game-setup.sh").read_text(encoding="utf-8")
SOURCE = re.search(r"<<'PYDOWNLOAD'\n(.*?)\nPYDOWNLOAD", SCRIPT, re.S).group(1)
MODULE = {"__name__": "game_download"}
exec(compile(SOURCE, "game-download", "exec"), MODULE)


class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "clients").mkdir()
        (self.root / "clients" / "ali.conf").write_bytes(b"PrivateKey = test-key\n")

    def issue(self):
        with patch.object(MODULE["time"], "time", return_value=1000):
            return "/" + MODULE["issue"](self.root, "ali")

    def get(self, path, now=1001):
        handler = MODULE["Handler"].__new__(MODULE["Handler"])
        handler.path, handler.wfile = path, io.BytesIO()
        handler.server = Mock(root=self.root)
        for method in ("send_response", "send_header", "end_headers", "send_error"):
            setattr(handler, method, Mock())
        with patch.object(MODULE["time"], "time", return_value=now):
            handler.do_GET()
        return handler

    def test_valid_download_is_an_attachment_and_never_cached(self):
        path = self.issue()
        handler = self.get(path)
        self.assertEqual(handler.wfile.getvalue(), b"PrivateKey = test-key\n")
        handler.send_response.assert_called_once_with(200)
        handler.send_header.assert_any_call("Cache-Control", "no-store")
        handler.send_header.assert_any_call("Content-Disposition", 'attachment; filename="ali.conf"')
        record = json.loads((self.root / "downloads" / "ali.json").read_text())
        self.assertNotIn(path.split("/")[-1].removesuffix(".conf"), json.dumps(record))

    def test_expires_after_exactly_one_day(self):
        path = self.issue()
        self.get(path, 1000 + 86400 - 1).send_response.assert_called_once_with(200)
        self.get(path, 1000 + 86400).send_error.assert_called_once_with(404)

    def test_regenerating_revokes_old_link(self):
        old, new = self.issue(), self.issue()
        self.assertNotEqual(old, new)
        self.get(old).send_error.assert_called_once_with(404)
        self.get(new).send_response.assert_called_once_with(200)

    def test_removed_player_cannot_download(self):
        path = self.issue()
        (self.root / "clients" / "ali.conf").unlink()
        self.get(path).send_error.assert_called_once_with(404)

    def test_rejects_listing_traversal_wrong_tokens_and_query_strings(self):
        path = self.issue()
        for bad in ("/", "/ali.conf", "/../state.env", "/ali/../../state.env", path + "?x=y",
                    path.replace("/ali/", "/bob/"), "/ali/" + "x" * 43 + ".conf"):
            with self.subTest(path=bad):
                handler = self.get(bad)
                handler.send_error.assert_called_once_with(404)
                self.assertEqual(handler.wfile.getvalue(), b"")

    def test_issuer_rejects_invalid_or_missing_players(self):
        for name in ("../ali", "missing", "ali;id"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                MODULE["issue"](self.root, name)

    @unittest.skipUnless(shutil.which("openssl"), "openssl is needed for the local HTTPS check")
    def test_https_download_and_certificate_reload(self):
        cert, key = self.root / "cert.pem", self.root / "key.pem"

        def renew():
            subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt",
                            "ec_paramgen_curve:P-256", "-nodes", "-days", "1", "-subj", "/CN=localhost",
                            "-addext", "subjectAltName=DNS:localhost", "-out", str(cert), "-keyout", str(key)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        renew()
        server = MODULE["Server"](("127.0.0.1", 0), MODULE["Handler"])
        server.root, server.cert, server.key = self.root, str(cert), str(key)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            url = "https://localhost:" + str(server.server_port) + "/" + MODULE["issue"](self.root, "ali")
            for _ in range(2):
                context = ssl.create_default_context(cafile=str(cert))
                with urllib.request.urlopen(url, context=context, timeout=5) as response:
                    self.assertEqual(response.read(), b"PrivateKey = test-key\n")
                renew()
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
