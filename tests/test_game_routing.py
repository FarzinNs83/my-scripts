"""Target-list validation and DNS/ipset generation, without network access."""
import contextlib
import io
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = (Path(__file__).resolve().parents[1] / "game-setup.sh").read_text(encoding="utf-8")
SOURCE = re.search(r"<<'PYROUTING'\n(.*?)\nPYROUTING", SCRIPT, re.S).group(1)
MODULE = {"__name__": "game_routing"}
exec(compile(SOURCE, "game-routing", "exec"), MODULE)


class RoutingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def update(self, action, *values):
        with contextlib.redirect_stdout(io.StringIO()):
            MODULE["update"](self.root, action, values)

    def test_defaults_include_services_assets_and_launchers(self):
        self.update("init")
        targets = MODULE["targets"](self.root)
        self.assertTrue({"claude.ai", "anthropic.com", "claudeusercontent.com", "chatgpt.com", "openai.com",
                         "oaistatic.com", "oaiusercontent.com", "discord.com", "discord.media", "discordapp.net",
                         "epicgames.com"}.issubset(targets))

    def test_normalizes_duplicates_hosts_and_cidrs(self):
        self.update("add", "EXAMPLE.COM.", "*.example.com", "203.0.113.7", "198.51.100.99/24")
        targets = MODULE["targets"](self.root)
        self.assertIn("example.com", targets)
        self.assertIn("203.0.113.7/32", targets)
        self.assertIn("198.51.100.0/24", targets)
        self.assertNotIn("*.example.com", targets)

    def test_import_supports_bom_crlf_comments_commas_and_multiple_files(self):
        first, second = self.root / "one.txt", self.root / "two.txt"
        first.write_bytes(b"\xef\xbb\xbf# list\r\nEXAMPLE.COM, 203.0.113.7 # comment\r\n")
        second.write_text("*.example.com\n198.51.100.0/24\n", encoding="utf-8")
        self.update("import", str(first), str(second))
        targets = MODULE["targets"](self.root)
        self.assertTrue({"example.com", "203.0.113.7/32", "198.51.100.0/24"}.issubset(targets))

    def test_invalid_import_cannot_partially_change_the_list(self):
        self.update("init")
        original = (self.root / "targets.txt").read_bytes()
        good, bad = self.root / "good.txt", self.root / "bad.txt"
        good.write_text("new.example.com\n", encoding="utf-8")
        bad.write_text("ok.example.com\ninvalid/domain\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            self.update("import", str(good), str(bad))
        self.assertEqual((self.root / "targets.txt").read_bytes(), original)

    def test_rejects_invalid_targets_and_unsupported_ipv6(self):
        for value in ("-bad.example.com", "x..example.com", "example.com;id", "example.com\nipset=x",
                      "example.com/route", "https://example.com", "999.1.1.1", "::/0", "0.0.0.0",
                      "a" * 64 + ".com"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                MODULE["normalize"](value)

    def test_dns_uses_link_source_only_for_listed_domains(self):
        (self.root / "targets.txt").write_text("example.com\n203.0.113.0/24\n0.0.0.0/0\n", encoding="utf-8")
        MODULE["render"](self.root, "10.68.68", "53001", "1.1.1.1, 8.8.8.8")
        config = (self.root / "dnsmasq.conf").read_text()
        self.assertIn("listen-address=10.68.68.1\n", config)
        self.assertIn("port=53001\n", config)
        self.assertIn("server=1.1.1.1\n", config)
        self.assertIn("server=/example.com/1.1.1.1@10.68.68.1\n", config)
        self.assertIn("ipset=/example.com/game-dns\n", config)
        self.assertNotIn("ipset=/203.0.113", config)
        restore = (self.root / "routes.ipset").read_text()
        self.assertIn("add game-ips-next 203.0.113.0/24\n", restore)
        self.assertIn("add game-ips-next 0.0.0.0/1\n", restore)
        self.assertIn("add game-ips-next 128.0.0.0/1\n", restore)
        self.assertIn("swap game-ips-next game-ips\n", restore)
        self.assertNotIn("flush game-dns", restore)

    @unittest.skipUnless(shutil.which("qrencode"), "qrencode is needed for the QR size check")
    def test_config_qr_keeps_values_and_download_qr_is_smaller(self):
        client = self.root / "ali.conf"
        config = ("[Interface]\nPrivateKey = " + "A" * 43 + "=\nAddress = 10.68.68.2/32\nDNS = 10.68.68.1\nMTU = 1280\n"
                  "Jc = 4\nJmin = 50\nJmax = 100\nS1 = 42\nS2 = 38\nH1 = 100000001\nH2 = 200000002\nH3 = 300000003\nH4 = 400000004\n"
                  "\n[Peer]\nPublicKey = " + "B" * 43 + "=\nPresharedKey = " + "C" * 43 +
                  "=\nEndpoint = game.example.com:41234\nAllowedIPs = 0.0.0.0/0, ::/0\nPersistentKeepalive = 25\n")
        client.write_text(config, encoding="utf-8")
        command = 'source "$1"; CLIENTS_DIR=$2; NAME=ali; qrencode() { cat; }; cmd_qr'
        compact = subprocess.run(["bash", "-c", command, "qr-test", str(Path(__file__).resolve().parents[1] / "game-setup.sh"),
                                  str(self.root)], check=True, capture_output=True, text=True).stdout
        expected = [line.replace(" = ", "=").replace(", ", ",") for line in config.splitlines() if line]
        self.assertEqual(compact.splitlines(), expected)
        self.assertEqual(client.read_text(), config)

        def width(payload):
            result = subprocess.run(["qrencode", "-t", "SVG", "-s", "1", "-m", "4", "-l", "L"],
                                    input=payload, text=True, check=True, capture_output=True).stdout
            return int(re.search(r'width="(\d+)"', result).group(1))

        download = "https://game.example.com:50000/ali/" + "X" * 43 + ".conf"
        self.assertLessEqual(width(compact), width(config))
        self.assertLess(width(download), width(compact))


if __name__ == "__main__":
    unittest.main()
