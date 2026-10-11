#!/usr/bin/env python3
"""Play one selected audio file on one selected IPv4 media receiver."""

import argparse
import http.server
import ipaddress
import mimetypes
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import socket
import stat
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET


RUN_SECONDS = 82
CONFIRM_SECONDS = 12
POLL_SECONDS = 0.2
SOAP_NS = "http://schemas.xmlsoap.org/soap/envelope/"
DLNA_FEATURES = "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"
DESCRIPTORS = ((9197, "/dmr"), (7676, "/dmr"), (49152, "/dmr"),
               (8200, "/rootDesc.xml"), (1400, "/xml/device_description.xml"))


class PlaybackError(Exception):
    pass


class Cancelled(Exception):
    pass


class PlaybackStarted(PlaybackError):
    """Play was accepted; retrying another protocol could play the clip twice."""


def emit(phase, message):
    print(f"[{phase}] {message}", flush=True)


def local_name(tag):
    return tag.rsplit("}", 1)[-1]


def child_text(node, name):
    return next((child.text or "" for child in node if local_name(child.tag) == name), "")


def scoped_url(url, target):
    parts = urllib.parse.urlsplit(url)
    try:
        valid = (parts.scheme == "http" and parts.hostname == target and
                 parts.username is None and parts.password is None and
                 0 < (parts.port or 80) < 65536)
    except ValueError:
        valid = False
    if not valid:
        raise PlaybackError("Receiver supplied a URL outside the selected IPv4 address")
    return urllib.parse.urlunsplit(parts._replace(fragment=""))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        raise PlaybackError("Receiver redirected a request; no other host was contacted")


OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())


def request_bytes(request, timeout):
    try:
        with OPENER.open(request, timeout=timeout) as response:
            raw = response.read(1024 * 1024 + 1)
    except urllib.error.HTTPError as error:
        with error:
            raw = error.read(64 * 1024)
        try:
            detail = soap_fault(ET.fromstring(raw))
        except ET.ParseError:
            detail = ""
        raise PlaybackError(f"HTTP {error.code}" + (f": {detail}" if detail else "")) from error
    if len(raw) > 1024 * 1024:
        raise PlaybackError("Receiver response exceeded 1 MiB")
    return raw


def soap_fault(root):
    fault = next((node for node in root.iter() if local_name(node.tag) == "Fault"), None)
    if fault is None:
        return ""
    values = {local_name(node.tag): node.text or "" for node in fault.iter() if not list(node)}
    return " ".join(filter(None, (values.get("errorCode"), values.get("errorDescription"),
                                   values.get("faultstring")))) or "SOAP Fault"


def parse_renderer(raw, location, target):
    root = ET.fromstring(raw)
    base = next((node.text for node in root.iter() if local_name(node.tag) == "URLBase" and node.text), location)
    base = scoped_url(urllib.parse.urljoin(location, base), target)
    services = {}
    for node in root.iter():
        if local_name(node.tag) != "service":
            continue
        kind, control = child_text(node, "serviceType"), child_text(node, "controlURL")
        if kind.startswith("urn:schemas-upnp-org:service:") and control:
            name = kind.split(":")[-2]
            if name in ("AVTransport", "RenderingControl"):
                services.setdefault(name, (kind, scoped_url(urllib.parse.urljoin(base, control), target)))
    if "AVTransport" not in services:
        raise PlaybackError("Descriptor has no AVTransport service")
    name = next((node.text for node in root.iter() if local_name(node.tag) == "friendlyName"), target)
    return name or target, services


def ssdp_locations(target, timeout=0.8):
    # A unicast search and source check avoid discovering or controlling other LAN devices.
    locations = []
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(timeout)
        request = (f'M-SEARCH * HTTP/1.1\r\nHOST: {target}:1900\r\n'
                   'MAN: "ssdp:discover"\r\nMX: 1\r\nST: ssdp:all\r\n\r\n')
        sock.sendto(request.encode("ascii"), (target, 1900))
        end = time.monotonic() + timeout
        while len(locations) < 12 and time.monotonic() < end:
            sock.settimeout(max(0.01, end - time.monotonic()))
            try:
                data, source = sock.recvfrom(8192)
            except socket.timeout:
                break
            if source[0] != target:
                continue
            for line in data.decode("latin-1").splitlines():
                if line.lower().startswith("location:"):
                    try:
                        url = scoped_url(line.split(":", 1)[1].strip(), target)
                    except PlaybackError:
                        continue
                    if url not in locations:
                        locations.append(url)
    return locations


def discover_renderer(target, deadline):
    emit("PROBE", f"DLNA descriptors on selected receiver {target}")
    try:
        locations = ssdp_locations(target, min(0.8, max(0.01, deadline - time.monotonic())))
    except OSError:
        locations = []
    locations.extend(f"http://{target}:{port}{path}" for port, path in DESCRIPTORS)
    for location in dict.fromkeys(locations):
        if time.monotonic() >= deadline:
            raise PlaybackError("Discovery time limit reached")
        try:
            raw = request_bytes(location, min(0.8, deadline - time.monotonic()))
            name, services = parse_renderer(raw, location, target)
            emit("DEVICE", name)
            return services
        except (OSError, urllib.error.URLError, ET.ParseError, PlaybackError):
            continue
    raise PlaybackError("No reachable DLNA AVTransport descriptor on the selected receiver")


class Renderer:
    def __init__(self, services):
        self.services = services

    def call(self, action, values=None, service="AVTransport", timeout=2):
        kind, control = self.services[service]
        envelope = ET.Element(f"{{{SOAP_NS}}}Envelope", {f"{{{SOAP_NS}}}encodingStyle": "http://schemas.xmlsoap.org/soap/encoding/"})
        body = ET.SubElement(envelope, f"{{{SOAP_NS}}}Body")
        operation = ET.SubElement(body, f"{{{kind}}}{action}")
        for name, value in (values or {"InstanceID": 0}).items():
            ET.SubElement(operation, name).text = str(value)
        request = urllib.request.Request(control, ET.tostring(envelope, encoding="utf-8", xml_declaration=True),
                                         {"Content-Type": 'text/xml; charset="utf-8"', "SOAPAction": f'"{kind}#{action}"'})
        try:
            root = ET.fromstring(request_bytes(request, timeout))
            fault = soap_fault(root)
            if fault:
                raise PlaybackError(fault)
            if not any(local_name(node.tag) == action + "Response" for node in root.iter()):
                raise PlaybackError("SOAP response did not acknowledge the action")
        except (OSError, urllib.error.URLError, ET.ParseError, PlaybackError) as error:
            raise PlaybackError(f"{action}: {error}") from error
        return {local_name(node.tag): node.text or "" for node in root.iter() if not list(node)}


class MediaServer:
    def __init__(self, target, path, host=None):
        self.target = target
        self.file = path.open("rb")
        self.size = os.fstat(self.file.fileno()).st_size
        self.mime = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        self.path = "/" + secrets.token_hex(16) + "/clip" + path.suffix.lower()
        self.bytes_sent = 0
        self.ranges = []
        self.last_fetch = 0
        self.lock = threading.Lock()
        self.closed = threading.Event()
        if host is None:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as route:
                route.connect((target, 1900))
                host = route.getsockname()[0]
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def setup(self):
                super().setup()
                self.connection.settimeout(2)

            def log_message(self, format, *args):
                pass

            def do_HEAD(self):
                self.respond(False)

            def do_GET(self):
                self.respond(True)

            def respond(self, send_body):
                if self.client_address[0] != owner.target or self.path != owner.path:
                    self.send_error(404)
                    return
                start, end = 0, owner.size - 1
                requested = self.headers.get("Range")
                if requested:
                    match = re.fullmatch(r"bytes=(\d*)-(\d*)", requested.strip())
                    if match and any(match.groups()):
                        left, right = match.groups()
                        if left:
                            start, end = int(left), min(int(right) if right else end, end)
                        else:
                            start = max(0, owner.size - int(right))
                    else:
                        start = owner.size
                    if start > end or start >= owner.size:
                        self.send_response(416)
                        self.send_header("Content-Range", f"bytes */{owner.size}")
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                        return
                self.send_response(206 if requested else 200)
                self.send_header("Content-Type", owner.mime)
                self.send_header("Content-Length", str(end - start + 1))
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("transferMode.dlna.org", "Streaming")
                self.send_header("contentFeatures.dlna.org", DLNA_FEATURES)
                if requested:
                    self.send_header("Content-Range", f"bytes {start}-{end}/{owner.size}")
                self.end_headers()
                sent = 0
                if send_body:
                    try:
                        while start + sent <= end and not owner.closed.is_set():
                            chunk = os.pread(owner.file.fileno(), min(65536, end - start - sent + 1), start + sent)
                            if not chunk:
                                break
                            self.wfile.write(chunk)
                            sent += len(chunk)
                    except (OSError, ValueError):
                        pass
                if sent:
                    with owner.lock:
                        owner.bytes_sent += sent
                        owner.ranges.append((start, start + sent))
                        owner.last_fetch = time.monotonic()
                    emit("FETCH", f"GET {sent} bytes from selected receiver" + (f" ({requested})" if requested else ""))

        try:
            self.server = http.server.ThreadingHTTPServer((host, 0), Handler)
        except BaseException:
            self.file.close()
            raise
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True)
        self.thread.start()
        self.url = f"http://{host}:{self.server.server_port}{self.path}"
        emit("SERVING", f"Selected file only, {self.size} bytes, {self.url}")

    def complete(self):
        with self.lock:
            end = 0
            for start, stop in sorted(self.ranges):
                if start > end:
                    return False
                end = max(end, stop)
            return end >= self.size

    def close(self):
        self.closed.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=1)
        self.file.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def metadata(path, server):
    root = ET.Element("DIDL-Lite", {"xmlns": "urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/",
                                  "xmlns:dc": "http://purl.org/dc/elements/1.1/",
                                  "xmlns:upnp": "urn:schemas-upnp-org:metadata-1-0/upnp/"})
    item = ET.SubElement(root, "item", {"id": "wifimancer-audio", "parentID": "0", "restricted": "1"})
    ET.SubElement(item, "dc:title").text = path.stem
    ET.SubElement(item, "upnp:class").text = "object.item.audioItem.musicTrack"
    ET.SubElement(item, "res", {"protocolInfo": f"http-get:*:{server.mime}:{DLNA_FEATURES}", "size": str(server.size)}).text = server.url
    return ET.tostring(root, encoding="unicode")


def stop_owned(renderer, url):
    try:
        current = renderer.call("GetMediaInfo", timeout=0.8).get("CurrentURI")
        if current == url:
            renderer.call("Stop", timeout=0.8)
            emit("CLEANUP", "Stopped this run's media URI")
        else:
            emit("CLEANUP", "Current URI differs; receiver playback left untouched")
    except PlaybackError as error:
        emit("CLEANUP", f"Could not verify current URI; no Stop sent ({error})")


def play_dlna(target, path, services, deadline):
    renderer = Renderer(services)
    attempted_set, accepted_play, ended = False, False, False
    with MediaServer(target, path) as server:
        try:
            if "RenderingControl" in services:
                for action, key in (("GetVolume", "CurrentVolume"), ("GetMute", "CurrentMute")):
                    try:
                        result = renderer.call(action, {"InstanceID": 0, "Channel": "Master"}, "RenderingControl", timeout=0.8)
                        emit("STATE", f"{key}={result.get(key, '?')} (preserved)")
                    except PlaybackError as error:
                        emit("STATE", f"{action} unavailable; volume/mute left unchanged ({error})")
            attempted_set = True
            renderer.call("SetAVTransportURI", {"InstanceID": 0, "CurrentURI": server.url,
                                                 "CurrentURIMetaData": metadata(path, server)})
            emit("ACCEPTED", "SetAVTransportURI accepted")
            renderer.call("Play", {"InstanceID": 0, "Speed": 1})
            accepted_play = True
            emit("ACCEPTED", "Play accepted; waiting for GET bytes and PLAYING")
            confirm_end = min(deadline, time.monotonic() + CONFIRM_SECONDS)
            playing, confirmed = False, False
            previous, next_uri_check = None, time.monotonic() + 1
            while time.monotonic() < deadline:
                state = renderer.call("GetTransportInfo", timeout=min(2, max(0.05, deadline - time.monotonic()))).get("CurrentTransportState", "")
                if state != previous:
                    emit("PLAYING" if state == "PLAYING" else "STATE", state or "No transport state returned")
                    previous = state
                playing = playing or state == "PLAYING"
                if playing and server.bytes_sent > 0 and not confirmed:
                    confirmed = True
                    emit("DELIVERED", "DLNA accepted Set/Play, receiver fetched bytes, PLAYING observed; audibility unverified")
                if state in ("STOPPED", "NO_MEDIA_PRESENT"):
                    ended = True
                    if confirmed:
                        return
                    raise PlaybackError("Playback ended without both target GET bytes and observed PLAYING")
                if not confirmed and time.monotonic() >= confirm_end:
                    raise PlaybackError(f"Playback not confirmed: fetched={server.bytes_sent} bytes, PLAYING={playing}")
                if time.monotonic() >= next_uri_check:
                    next_uri_check = time.monotonic() + 1
                    try:
                        current = renderer.call("GetMediaInfo", timeout=min(0.8, max(0.05, deadline - time.monotonic()))).get("CurrentURI")
                    except PlaybackError:
                        current = None
                    if current and current != server.url:
                        ended = True
                        if confirmed:
                            emit("STATE", "Receiver switched to other media; playback left untouched")
                            return
                        raise PlaybackError("Receiver switched media before delivery was confirmed")
                time.sleep(POLL_SECONDS)
            raise PlaybackError("Run time limit reached; this run's still-active DLNA clip will be stopped (truncated)")
        except PlaybackError as error:
            if accepted_play:
                raise PlaybackStarted(str(error)) from error
            raise
        finally:
            if attempted_set and not ended:
                stop_owned(renderer, server.url)


def port_open(target, ports):
    for port in ports:
        try:
            with socket.create_connection((target, port), timeout=0.4):
                return True
        except OSError:
            pass
    return False


def run_command(command, timeout):
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    except FileNotFoundError as error:
        raise PlaybackError(f"{command[0]} is not installed; no automatic installation attempted") from error
    try:
        try:
            output, _ = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired as error:
            raise PlaybackError(f"{Path(command[0]).name} timed out after {timeout:.1f}s") from error
        if output:
            emit("TOOL", output[-8192:].decode(errors="replace").strip())
        if process.returncode:
            raise PlaybackError(f"{Path(command[0]).name} exited with status {process.returncode}")
    finally:
        # A tool can exit while a child remains in its private process group.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        if process.poll() is None:
            try:
                process.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=0.5)
        if process.stdout is not None:
            process.stdout.close()


def play_external(target, path, protocol, deadline):
    tool, ports = {"airplay": ("atvremote", (7000,)), "cast": ("catt", (8008, 8009)), "sonos": ("sonos", (1400,))}[protocol]
    executable = shutil.which(tool)
    if not executable:
        raise PlaybackError(f"{tool} is not installed; no automatic installation attempted")
    if not port_open(target, ports):
        raise PlaybackError(f"No reachable {protocol} playback port on selected receiver")
    with MediaServer(target, path) as server:
        command = {"airplay": [executable, "--address", target, "--protocol", "airplay", f"play_url={server.url}"],
                   "cast": [executable, "-d", target, "cast", server.url],
                   "sonos": [executable, target, "play_uri", server.url]}[protocol]
        emit("TRY", f"{protocol} using installed {tool}; volume and mute unchanged")
        accepted = False
        try:
            run_command(command, min(12, max(0.05, deadline - time.monotonic())))
            accepted = True
            confirm_end = min(deadline, time.monotonic() + CONFIRM_SECONDS)
            while time.monotonic() < deadline:
                if server.complete() and time.monotonic() - server.last_fetch >= 2:
                    emit("DELIVERED", f"{protocol} command exited 0 and selected receiver fetched complete file; audibility unverified")
                    return
                if not server.bytes_sent and time.monotonic() >= confirm_end:
                    raise PlaybackError(f"{protocol} command exited 0 but receiver did not GET audio bytes")
                time.sleep(POLL_SECONDS)
            raise PlaybackError(f"Run time limit reached before complete {protocol} file delivery; stream may be truncated")
        except PlaybackError as error:
            if accepted or server.bytes_sent:
                raise PlaybackStarted(str(error)) from error
            raise


def run(target, path, protocol):
    deadline = time.monotonic() + RUN_SECONDS
    errors = []
    if protocol in ("auto", "dlna"):
        try:
            services = discover_renderer(target, deadline)
            emit("TRY", "DLNA AVTransport; volume and mute unchanged")
            play_dlna(target, path, services, deadline)
            return
        except PlaybackError as error:
            emit("MISS", str(error))
            errors.append(str(error))
            if protocol == "dlna" or isinstance(error, PlaybackStarted):
                raise
    for fallback in (("airplay", "cast", "sonos") if protocol == "auto" else ("airplay",)):
        if time.monotonic() >= deadline:
            break
        try:
            play_external(target, path, fallback, deadline)
            return
        except PlaybackError as error:
            emit("MISS", f"{fallback}: {error}")
            errors.append(str(error))
            if isinstance(error, PlaybackStarted):
                raise
    raise PlaybackError("No confirmed playback path. " + "; ".join(errors))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", required=True, type=ipaddress.IPv4Address)
    parser.add_argument("--file", required=True, type=Path)
    parser.add_argument("--protocol", choices=("auto", "dlna", "airplay"), default="auto")
    args = parser.parse_args()
    try:
        path = args.file.expanduser().resolve(strict=True)
        if not stat.S_ISREG(path.stat().st_mode) or not path.stat().st_size:
            raise PlaybackError("Selected audio file must be a nonempty regular file")
        def cancel(signum, frame):
            # Avoid repeated cancellation interrupting bounded, ownership-checked cleanup.
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            raise Cancelled()
        signal.signal(signal.SIGTERM, cancel)
        signal.signal(signal.SIGINT, cancel)
        run(str(args.target), path, args.protocol)
        emit("RESULT", "Delivery verified. Hearing the clip requires confirmation at the receiver.")
        return 0
    except Cancelled:
        emit("CANCELLED", "This run's server and child process closed")
        return 130
    except (OSError, PlaybackError) as error:
        emit("ERROR", str(error))
        return 1


if __name__ == "__main__":
    sys.exit(main())
