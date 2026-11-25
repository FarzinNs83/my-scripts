"""Offline checks for the Python embedded in backpack-setup.sh."""
import ast
import io
import json
from pathlib import Path
import re
import sys
import unittest
from unittest.mock import Mock, patch


SCRIPT = (Path(__file__).resolve().parents[1] / "backpack-setup.sh").read_text(encoding="utf-8")
PANEL, PROXY = re.findall(r"<< 'PYEOF' \|\| true\n(.*?)\nPYEOF", SCRIPT, re.S)


class BackPackTests(unittest.TestCase):
    def proxy(self, path):
        namespace = {}
        with patch.object(sys, "argv", ["proxy", "2095", "panel.example.com", "0", "4201,4202", "/sub/"]), \
                patch("http.server.ThreadingHTTPServer"):
            exec(compile(PROXY, "proxy", "exec"), namespace)
        handler = namespace["H"].__new__(namespace["H"])
        handler.path, handler.headers, handler.wfile = path, {}, io.BytesIO()
        for method in ("send_response", "send_header", "end_headers", "send_error"):
            setattr(handler, method, Mock())
        return handler

    def test_embedded_python_compiles(self):
        compile(PANEL, "panel", "exec")
        compile(PROXY, "proxy", "exec")

    def test_proxy_rejects_non_subscription_paths(self):
        for path in ("/", "/panel/", "/sub/", "/sub/../admin", "http://elsewhere/sub/token", "//elsewhere/sub/token"):
            with self.subTest(path=path), patch("http.client.HTTPConnection") as connection:
                handler = self.proxy(path)
                handler.do_GET()
                handler.send_error.assert_called_once_with(404)
                connection.assert_not_called()

    def test_proxy_fails_over_and_closes_connections(self):
        bad, good = Mock(), Mock()
        bad.getresponse.return_value.status = 503
        response = good.getresponse.return_value
        response.status, response.read.return_value = 200, b"subscription"
        response.getheaders.return_value = [("Connection", "close"), ("Subscription-Userinfo", "upload=1")]
        handler = self.proxy("/sub/token?target=v2ray")
        with patch("http.client.HTTPConnection", side_effect=[bad, good]):
            handler.do_GET()
        self.assertEqual(handler.wfile.getvalue(), b"subscription")
        handler.send_response.assert_called_once_with(200)
        handler.send_header.assert_any_call("Subscription-Userinfo", "upload=1")
        self.assertNotIn(("Connection", "close"), [c.args for c in handler.send_header.call_args_list])
        bad.close.assert_called_once()
        good.close.assert_called_once()

    def panel_functions(self, **namespace):
        tree = ast.parse(PANEL)
        definitions = ast.Module(body=[n for n in tree.body if isinstance(n, (ast.FunctionDef, ast.Import, ast.ImportFrom))], type_ignores=[])
        namespace.update(REMARK="BackPack", sys=sys)
        exec(compile(definitions, "panel-functions", "exec"), namespace)
        return namespace

    def test_inbound_list_failure_is_not_treated_as_empty_panel(self):
        namespace = self.panel_functions()
        namespace["api"] = Mock(return_value={"success": False, "msg": "unavailable"})
        with self.assertRaises(SystemExit):
            namespace["ours"]()

    def test_host_write_failure_stops_setup(self):
        namespace = self.panel_functions()
        namespace["ours"] = lambda: {"id": 1}
        namespace["api"] = Mock(side_effect=[{"success": True, "obj": []}, {"success": False, "msg": "rejected"}])
        with self.assertRaises(SystemExit):
            namespace["hosts"]("192.0.2.1", ["tcp:2101"])

    def test_client_probe_accepts_flat_and_vnext_vless_settings(self):
        server = {"address": "192.0.2.1", "port": 2101, "id": "test"}
        for settings in (server, {"vnext": [server]}):
            with self.subTest(settings=settings):
                namespace = self.panel_functions(DOMAIN="panel.example.com")
                namespace["api"] = Mock(return_value={"obj": {}})
                namespace["curl"] = Mock(side_effect=[json.dumps([{"outbounds": [
                    {"tag": "proxy", "protocol": "vless", "settings": settings}]}]), "204"])
                namespace["glob"] = Mock()
                namespace["glob"].glob.return_value = ["/fake/xray"]
                namespace["socket"] = Mock()
                namespace["socket"].socket.return_value.getsockname.return_value = ("127.0.0.1", 23000)
                namespace["time"] = Mock()
                process = Mock()
                process.poll.return_value = None
                namespace["subprocess"] = Mock()
                namespace["subprocess"].Popen.return_value = process
                with patch("sys.stdout", new_callable=io.StringIO) as output:
                    namespace["test_clients"]("subid", "192.0.2.1", ["tcp:2101"])
                self.assertIn("E2E_tcp=ok", output.getvalue())
                process.terminate.assert_called_once()


if __name__ == "__main__":
    unittest.main()
