import contextlib
import http.server
import importlib.util
import io
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET


SCRIPT = Path(__file__).resolve().parents[2] / "Resources/Data/audio_push.py"
spec = importlib.util.spec_from_file_location("audio_push", SCRIPT)
audio = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audio)
AVT = "urn:schemas-upnp-org:service:AVTransport:1"
RCS = "urn:schemas-upnp-org:service:RenderingControl:1"


class Receiver:
    """Loopback receiver exercises real HTTP/SOAP without contacting a LAN."""
    def __init__(self, fetch=True, states=None, fault=None, replace_uri=False):
        self.fetch = fetch
        self.states = states or ["TRANSITIONING", "PLAYING", "PLAYING", "STOPPED"]
        self.fault = fault
        self.replace_uri = replace_uri
        self.calls = []
        self.uri = ""
        self.played = threading.Event()
        self.fetched = threading.Event()
        self.fetch_errors = []
        self.fetch_threads = []
        self.state_index = 0
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(owner.description().encode())

            def do_POST(self):
                data = self.rfile.read(int(self.headers["Content-Length"]))
                root = ET.fromstring(data)
                action = self.headers["SOAPAction"].strip('"').split("#")[-1]
                values = {audio.local_name(node.tag): node.text or "" for node in root.iter() if not list(node)}
                owner.calls.append((self.path, action, values))
                if owner.fault and action == owner.fault[0]:
                    self.send_response(owner.fault[1])
                    self.end_headers()
                    self.wfile.write(b'<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><faultstring>UPnPError</faultstring><detail><UPnPError><errorCode>701</errorCode><errorDescription>Transition not available</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>')
                    return
                result = {}
                if action == "SetAVTransportURI":
                    owner.uri = values["CurrentURI"]
                    owner.metadata = ET.fromstring(values["CurrentURIMetaData"])
                elif action == "Play":
                    owner.played.set()
                    if owner.fetch:
                        thread = threading.Thread(target=owner.fetch_audio, daemon=True)
                        owner.fetch_threads.append(thread)
                        thread.start()
                elif action == "GetTransportInfo":
                    state = owner.states[min(owner.state_index, len(owner.states) - 1)]
                    if owner.fetched.is_set() or not owner.fetch:
                        owner.state_index += 1
                    result = {"CurrentTransportState": state, "CurrentTransportStatus": "OK", "CurrentSpeed": "1"}
                elif action == "GetMediaInfo":
                    result = {"CurrentURI": "http://other.example/movie" if owner.replace_uri else owner.uri}
                elif action == "GetVolume":
                    result = {"CurrentVolume": "30"}
                elif action == "GetMute":
                    result = {"CurrentMute": "0"}
                envelope = ET.Element(f"{{{audio.SOAP_NS}}}Envelope")
                body = ET.SubElement(envelope, f"{{{audio.SOAP_NS}}}Body")
                response = ET.SubElement(body, f"{{{RCS if action in ('GetMute', 'GetVolume') else AVT}}}{action}Response")
                for name, value in result.items():
                    ET.SubElement(response, name).text = value
                self.send_response(200)
                self.end_headers()
                self.wfile.write(ET.tostring(envelope))

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"
        self.services = {"AVTransport": (AVT, self.base + "/control/transport"),
                         "RenderingControl": (RCS, self.base + "/control/rendering")}

    def description(self):
        return f'''<root xmlns="urn:schemas-upnp-org:device-1-0"><device><friendlyName>Fixture TV</friendlyName><serviceList>
          <service><serviceType>{RCS}</serviceType><controlURL>../control/rendering</controlURL></service>
          <service><serviceType>{AVT}</serviceType><controlURL>../control/transport</controlURL></service>
          </serviceList></device></root>'''

    def fetch_audio(self):
        try:
            with urllib.request.urlopen(urllib.request.Request(self.uri, method="HEAD"), timeout=1) as response:
                if response.headers["Accept-Ranges"] != "bytes":
                    raise AssertionError("Missing range support")
            with urllib.request.urlopen(urllib.request.Request(self.uri, headers={"Range": "bytes=0-"}), timeout=1) as response:
                if response.status != 206 or response.read() != b"test audio" * 100:
                    raise AssertionError("Range response did not match selected file")
            self.fetched.set()
        except Exception as error:
            self.fetch_errors.append(error)

    def close(self):
        for thread in self.fetch_threads:
            thread.join(timeout=2)
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=1)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


class MediaTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.file = Path(self.temp.name) / "literal ' audio $(touch nope).mp3"
        self.file.write_bytes(b"test audio" * 100)
        self.output = io.StringIO()
        self.capture = contextlib.redirect_stdout(self.output)
        self.capture.__enter__()

    def tearDown(self):
        self.capture.__exit__(None, None, None)
        self.temp.cleanup()

    def test_descriptor_service_order_and_relative_control_urls(self):
        with Receiver() as tv:
            name, services = audio.parse_renderer(tv.description().encode(), tv.base + "/device/root.xml", "127.0.0.1")
            self.assertEqual(name, "Fixture TV")
            self.assertEqual(services["AVTransport"], tv.services["AVTransport"])
            self.assertEqual(services["RenderingControl"], tv.services["RenderingControl"])
            raw = tv.description().replace("<device>", f"<URLBase>{tv.base}/base/</URLBase><device>").replace("../control/transport", "transport")
            _, services = audio.parse_renderer(raw.encode(), tv.base + "/elsewhere/root.xml", "127.0.0.1")
            self.assertEqual(services["AVTransport"][1], tv.base + "/base/transport")

    def test_external_control_url_and_redirect_rejected(self):
        with Receiver() as tv:
            raw = tv.description().replace("../control/transport", "http://192.0.2.4/control")
            with self.assertRaises(audio.PlaybackError):
                audio.parse_renderer(raw.encode(), tv.base + "/root.xml", "127.0.0.1")
        for bad in ("http://127.0.0.2/desc", "https://127.0.0.1/desc", "http://user@127.0.0.1/desc", "http://127.0.0.1:99999/desc"):
            with self.assertRaises(audio.PlaybackError):
                audio.scoped_url(bad, "127.0.0.1")
        with self.assertRaises(audio.PlaybackError):
            audio.NoRedirect().redirect_request(None, None, 302, "redirect", {}, "http://192.0.2.4/")

    def test_ssdp_replies_only_selected_address_locations(self):
        class FakeSocket:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def settimeout(self, value): pass
            def sendto(self, data, dest): self.dest = dest
            responses = iter(((b"HTTP/1.1 200 OK\r\nLOCATION: http://127.0.0.2/root\r\n", ("127.0.0.2", 1900)),
                              (b"HTTP/1.1 200 OK\r\nLOCATION: http://127.0.0.2/root\r\n", ("127.0.0.1", 1900)),
                              (b"HTTP/1.1 200 OK\r\nLOCATION: http://127.0.0.1/root\r\n", ("127.0.0.1", 1900))))
            def recvfrom(self, size):
                try: return next(self.responses)
                except StopIteration: raise socket.timeout()
        fake = FakeSocket()
        with patch.object(audio.socket, "socket", return_value=fake):
            self.assertEqual(audio.ssdp_locations("127.0.0.1"), ["http://127.0.0.1/root"])
            self.assertEqual(fake.dest, ("127.0.0.1", 1900))

    def test_discovery_uses_descriptor_not_hardcoded_control_path(self):
        with Receiver() as tv, patch.object(audio, "ssdp_locations", return_value=[tv.base + "/device/root.xml"]):
            services = audio.discover_renderer("127.0.0.1", time.monotonic() + 1)
            self.assertEqual(services["AVTransport"][1], tv.base + "/control/transport")

    def test_http_head_range_suffix_invalid_path_and_wrong_target(self):
        with audio.MediaServer("127.0.0.1", self.file) as server:
            with urllib.request.urlopen(urllib.request.Request(server.url, method="HEAD")) as response:
                self.assertEqual(response.headers["Content-Length"], "1000")
                self.assertEqual(response.headers["Content-Type"], "audio/mpeg")
                self.assertEqual(response.read(), b"")
            self.assertEqual(server.bytes_sent, 0, "HEAD is not delivery evidence")
            for requested, wanted, content_range in (("bytes=2-8", self.file.read_bytes()[2:9], "bytes 2-8/1000"),
                                                      ("bytes=-5", self.file.read_bytes()[-5:], "bytes 995-999/1000"),
                                                      ("bytes=998-", self.file.read_bytes()[998:], "bytes 998-999/1000")):
                with urllib.request.urlopen(urllib.request.Request(server.url, headers={"Range": requested})) as response:
                    self.assertEqual(response.status, 206)
                    self.assertEqual(response.headers["Content-Range"], content_range)
                    self.assertEqual(response.read(), wanted)
            for invalid in ("bytes=1000-", "bytes=8-2", "bytes=-0", "bytes=0-1,4-5", "items=0-1"):
                with self.assertRaises(urllib.error.HTTPError) as error:
                    urllib.request.urlopen(urllib.request.Request(server.url, headers={"Range": invalid}))
                self.assertEqual(error.exception.code, 416)
                error.exception.close()
            with self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(server.url + "/../other")
            self.assertEqual(error.exception.code, 404)
            error.exception.close()
            self.assertFalse(server.complete())
        with audio.MediaServer("127.0.0.2", self.file, host="127.0.0.1") as server:
            with self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(server.url)
            self.assertEqual(error.exception.code, 404)
            error.exception.close()
            self.assertEqual(server.bytes_sent, 0)

    def test_two_servers_are_independent_and_close_only_their_port(self):
        first = audio.MediaServer("127.0.0.1", self.file)
        with audio.MediaServer("127.0.0.1", self.file) as second:
            self.assertNotEqual(first.url, second.url)
            first_url = first.url
            first.close()
            with self.assertRaises(urllib.error.URLError):
                urllib.request.urlopen(first_url, timeout=0.2)
            with urllib.request.urlopen(second.url) as response:
                self.assertEqual(response.read(), self.file.read_bytes())

    def test_soap_fault_500_or_200_prevents_play_and_cleanup_preserves_other_uri(self):
        for status in (500, 200):
            with self.subTest(status=status), Receiver(fault=("SetAVTransportURI", status), replace_uri=True) as tv:
                with self.assertRaisesRegex(audio.PlaybackError, "701.*Transition not available"):
                    audio.play_dlna("127.0.0.1", self.file, tv.services, time.monotonic() + 1)
                actions = [call[1] for call in tv.calls]
                self.assertNotIn("Play", actions)
                self.assertNotIn("Stop", actions)

    def test_get_bytes_and_brief_playing_are_required_and_volume_preserved(self):
        with Receiver() as tv, patch.object(audio, "POLL_SECONDS", 0.01):
            audio.play_dlna("127.0.0.1", self.file, tv.services, time.monotonic() + 2)
            self.assertTrue(tv.fetched.is_set())
            self.assertFalse(tv.fetch_errors)
            actions = [call[1] for call in tv.calls]
            self.assertNotIn("SetVolume", actions)
            self.assertNotIn("SetMute", actions)
            self.assertNotIn("Stop", actions)
            self.assertIn("[DELIVERED] DLNA", self.output.getvalue())
            self.assertIn("audibility unverified", self.output.getvalue())
            res = next(node for node in tv.metadata.iter() if audio.local_name(node.tag) == "res")
            self.assertEqual(res.text, tv.uri)
            self.assertEqual(res.attrib["size"], "1000")

    def test_no_get_or_no_playing_is_not_success_and_no_auto_retry_after_play(self):
        for fetch, states in ((False, ["PLAYING"]), (True, ["TRANSITIONING", "STOPPED"])):
            with self.subTest(fetch=fetch), Receiver(fetch=fetch, states=states) as tv, \
                 patch.object(audio, "POLL_SECONDS", 0.01), patch.object(audio, "CONFIRM_SECONDS", 0.1), \
                 patch.object(audio, "discover_renderer", return_value=tv.services), patch.object(audio, "play_external") as fallback:
                with self.assertRaises(audio.PlaybackStarted):
                    audio.run("127.0.0.1", self.file, "auto")
                fallback.assert_not_called()
                self.assertNotIn("[DELIVERED]", self.output.getvalue())

    def test_deadline_stops_only_owned_uri_and_reports_truncation(self):
        with Receiver(states=["PLAYING"]) as tv, patch.object(audio, "POLL_SECONDS", 0.01):
            with self.assertRaisesRegex(audio.PlaybackStarted, "truncated"):
                audio.play_dlna("127.0.0.1", self.file, tv.services, time.monotonic() + 0.15)
            self.assertIn("Stop", [call[1] for call in tv.calls])
        with Receiver(states=["PLAYING"], replace_uri=True) as tv, patch.object(audio, "POLL_SECONDS", 0.01):
            with self.assertRaises(audio.PlaybackStarted):
                audio.play_dlna("127.0.0.1", self.file, tv.services, time.monotonic() + 0.15)
            self.assertNotIn("Stop", [call[1] for call in tv.calls])

    def test_subprocess_missing_failure_timeout_and_descendant_cancellation(self):
        with self.assertRaisesRegex(audio.PlaybackError, "not installed"):
            audio.run_command([str(Path(self.temp.name) / "missing-tool")], 0.1)
        with self.assertRaisesRegex(audio.PlaybackError, "status 7"):
            audio.run_command([sys.executable, "-c", "import sys; print('rejected'); sys.exit(7)"], 1)
        child_pid = Path(self.temp.name) / "child.pid"
        command = [sys.executable, "-c", f"import os,time; open({str(child_pid)!r},'w').write(str(os.getpid())); time.sleep(30)"]
        with self.assertRaisesRegex(audio.PlaybackError, "timed out"):
            audio.run_command(command, 0.15)
        with self.assertRaises(ProcessLookupError):
            os.kill(int(child_pid.read_text()), 0)
        with patch.object(audio.subprocess.Popen, "communicate", side_effect=audio.Cancelled()):
            with self.assertRaises(audio.Cancelled):
                audio.run_command([sys.executable, "-c", "import time;time.sleep(30)"], 1)

    def test_exited_tool_cannot_leave_its_own_background_child(self):
        child_pid = Path(self.temp.name) / "grandchild.pid"
        program = ("import subprocess,sys; "
                   "p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'], "
                   "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); "
                   f"open({str(child_pid)!r},'w').write(str(p.pid))")
        try:
            audio.run_command([sys.executable, "-c", program], 1)
            pid = int(child_pid.read_text())
            end = time.monotonic() + 1
            while time.monotonic() < end:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.01)
            else:
                self.fail("Exited media command left its background process running")
        finally:
            if child_pid.exists():
                try:
                    os.kill(int(child_pid.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_optional_exit_zero_without_get_is_failure_and_missing_tool_clear(self):
        with patch.object(audio.shutil, "which", return_value=None):
            with self.assertRaisesRegex(audio.PlaybackError, "atvremote is not installed"):
                audio.play_external("127.0.0.1", self.file, "airplay", time.monotonic() + 1)
        with patch.object(audio.shutil, "which", return_value="atvremote"), patch.object(audio, "port_open", return_value=True), \
             patch.object(audio, "run_command"), patch.object(audio, "CONFIRM_SECONDS", 0.05), patch.object(audio, "POLL_SECONDS", 0.01):
            with self.assertRaisesRegex(audio.PlaybackError, "did not GET"):
                audio.play_external("127.0.0.1", self.file, "airplay", time.monotonic() + 0.5)

    def test_optional_success_requires_real_exit_and_complete_fresh_fetch(self):
        def fake_tool(command, timeout):
            url = command[-1].split("play_url=", 1)[-1]
            with urllib.request.urlopen(url) as response:
                self.assertEqual(response.read(), self.file.read_bytes())
        with patch.object(audio.shutil, "which", return_value="atvremote"), patch.object(audio, "port_open", return_value=True), \
             patch.object(audio, "run_command", side_effect=fake_tool):
            audio.play_external("127.0.0.1", self.file, "airplay", time.monotonic() + 3)
        self.assertIn("command exited 0", self.output.getvalue())

    def test_optional_fetch_then_failure_or_timeout_never_retries_other_protocol(self):
        original_command = audio.run_command
        original_external = audio.play_external
        for ending in ("sys.exit(7)", "time.sleep(30)"):
            self.output.seek(0)
            self.output.truncate()
            tool = Path(self.temp.name) / "fixture-atvremote"
            tool.write_text(f"#!{sys.executable}\nimport sys,time,urllib.request\n"
                            "url=next(arg.split('=',1)[1] for arg in sys.argv if arg.startswith('play_url='))\n"
                            "with urllib.request.urlopen(url) as response: response.read()\n" + ending + "\n")
            tool.chmod(0o755)
            attempted = []
            def external(target, path, protocol, deadline):
                attempted.append(protocol)
                return original_external(target, path, protocol, deadline)
            with self.subTest(ending=ending), patch.object(audio.shutil, "which", return_value=str(tool)), \
                 patch.object(audio, "port_open", return_value=True), \
                 patch.object(audio, "discover_renderer", side_effect=audio.PlaybackError("No DLNA renderer")), \
                 patch.object(audio, "run_command", side_effect=lambda command, timeout: original_command(command, 1)), \
                 patch.object(audio, "play_external", side_effect=external):
                with self.assertRaises(audio.PlaybackStarted):
                    audio.run("127.0.0.1", self.file, "auto")
                self.assertEqual(attempted, ["airplay"])
                self.assertIn("[FETCH] GET", self.output.getvalue())

    def test_sigterm_closes_server_and_stops_owned_clip_but_not_replacement(self):
        for replace in (False, True):
            with self.subTest(replace=replace), Receiver(states=["PLAYING"], replace_uri=replace) as tv:
                program = (f"import sys; sys.path.insert(0, {str(SCRIPT.parent)!r}); import audio_push as a; "
                           f"a.discover_renderer=lambda target,deadline: {tv.services!r}; "
                           "sys.exit(a.main())")
                process = subprocess.Popen([sys.executable, "-c", program, "--target", "127.0.0.1", "--file", str(self.file), "--protocol", "dlna"],
                                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                try:
                    self.assertTrue(tv.played.wait(3))
                    self.assertTrue(tv.fetched.wait(2))
                    process.send_signal(signal.SIGTERM)
                    output, _ = process.communicate(timeout=4)
                    self.assertEqual(process.returncode, 130, output.decode())
                    self.assertIn(b"[CANCELLED]", output)
                    self.assertEqual("Stop" in [call[1] for call in tv.calls], not replace)
                    with self.assertRaises(urllib.error.URLError):
                        urllib.request.urlopen(tv.uri, timeout=0.2)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()


if __name__ == "__main__":
    unittest.main(verbosity=2)
