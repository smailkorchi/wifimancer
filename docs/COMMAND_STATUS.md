# Command implementation and verification status

Audit date: 2026-10-11. This inventory covers **all 99 Arsenal recipes across 17 categories** in `App/Kali/AttackCatalog.swift`. Every recipe still needs work or broader verification. An implemented shell template is not evidence that its advertised result works. No catalog command, radio operation, network disruption or media playback was run for this audit.

The [machine-readable inventory](command-status.json) contains stable IDs, exact titles, routes, declared install metadata, additional requirements and evidence level. Its source fingerprint records the catalog snapshot; regenerate/review this document when the catalog changes.

These are audit labels, not execution guards currently enforced by the app. In particular, `scope-blocked` means **do not run**: those recipes still require disabling or redesign before they can be offered as supported operations.

## Status and evidence

| Status | Count | Meaning |
| --- | ---: | --- |
| `incomplete` | 5 | Required inputs, evidence, or workflow are absent. |
| `known-defect` | 20 | Source contains an observable mismatch or failure path; needs correction before supported status. |
| `limited-confirmation` | 1 | Narrow historical live report; broader compatibility is unverified. |
| `needs-validation` | 64 | Recipe exists; no end-to-end compatibility claim. Concrete verification work remains. |
| `sample-only` | 7 | Prints instructions/examples instead of performing the advertised operation. |
| `scope-blocked` | 2 | Operation is not constrained to the selected authorized scope; keep unavailable pending redesign. |

`limited-confirmation` is a historical maintainer/user report of one successful SMART audio run through DLNA on one TV. It is not a current test and does not certify other protocols, all files, video, or other devices. Existing loopback/argument-quoting tests cover the shared selected-file audio implementation; they are not physical-device acceptance.

## Execution routes and dependencies

| Route | Count | Current behavior |
| --- | ---: | --- |
| `auto` | 27 | Mac for a guessed same /24 prefix; otherwise remote Kali. This is not a reliable route or permission check. |
| `kali` | 41 | Remote SSH execution; the remote host must actually reach the authorized target/network. |
| `local` | 18 | Current Mac user session; dependencies and OS permissions may be required. |
| `kaliRange` | 13 | Remote Linux radio in physical range; UI confirmation does not establish scope or capabilities. |

Dependency cells below show the primary tool and any declared installer. The JSON also lists secondary requirements. Installer metadata does not establish that a package exists or is installed. Missing apt/brew metadata means **no automatic install for that route**.

## Shared work before claiming support

- **scope:** Authorization is a session checkbox, not a per-run allowlist. RF-range confirmation is a UI gate and is not enforced inside runSelected(). Network-wide commands can ignore the selected target. Scope-blocked entries should remain unavailable pending explicit scope review.
- **shell-arguments:** Attack.expanded substitutes names/SSIDs directly into shell strings. General recipes need typed/quoted arguments and fail-closed missing-input validation. The selected-file MediaAudioCommand path already quotes its arguments and has injection fixtures.
- **routing:** Auto routing compares only the first three IPv4 octets, rather than actual routes/netmasks; it does not prove remote reachability. Multicast/Bluetooth/RF tools often inspect the executor network, not the chosen LAN device.
- **dependencies:** Auto-install checks one declared executable/package only. Secondary binaries, wordlists, scripts, driver capabilities, noninteractive sudo, package availability and version compatibility are generally not preflighted. A nil package does not mean installed.
- **outcomes:** Most commands pipe into head/tail without pipefail. The final shell exit can be zero after the tool fails. The UI treats exit zero as success; generic recipes have no capability/finding outcome schema.
- **cancellation:** LocalClient terminates the shell and KaliClient terminates ssh; this does not prove child or remote jobs stopped. Shared temporary files and broad pkill lack per-run ownership. cancelled status/old-run events need explicit lifecycle handling.
- **media:** The three selected-file actions share a quoted bundled audio runner with scoped HTTP serving, SOAP parsing and delivery checks. This is stronger than old URL templates, but audio metadata and a fixed run limit do not establish arbitrary file/video compatibility. The UI has an implicit Downloads clip fallback when no file is selected; remove the fallback and require an explicit readable file.
- **range-probe:** KaliRangeProbe creates/deletes monitor interfaces and runs a scan; it is not a pure read. It hardcodes interface patterns, mixes interactive sudo with a batch SSH transport, and does not make scan/cleanup failure a reliable capability result.
- **verification:** No recipe was dispatched during this audit. Except the narrow historical SMART/DLNA report, end-to-end target success is unverified. Dependency metadata, danger labels and explanatory prose are claims to review, not compatibility evidence.

## Complete Arsenal inventory

### ad — 6 recipes

| Stable ID and title | Route | Declared tool / installer | Status and specific remaining work |
| --- | --- | --- | --- |
| `ad.responder.short`<br>Responder LLMNR/NBT-NS poisoning (60 s) | `kali` | `responder`; manual dependency | **scope-blocked** — Hardcoded remote interface and network-wide poisoning are not constrained to the selected device/scope. Keep unavailable pending scope/lifecycle redesign. |
| `ad.kerberoast`<br>Kerberoast (impacket-getuserspns) | `kali` | `impacket`; manual dependency | **incomplete** — Missing required domain/principal input; no credential handling or protected hash-artifact workflow. |
| `ad.asreproast`<br>ASREPRoast (impacket-GetNPUsers) | `kali` | `impacket`; apt: impacket-scripts | **sample-only** — Only prints a sample; domain/user-list inputs and artifact handling are not implemented. |
| `ad.netexec.spray`<br>Password spray AD users (netexec smb) | `kali` | `netexec`; manual dependency | **sample-only** — Only prints examples; no credentials/user-list UI, lockout budget or result parser. |
| `ad.bloodhound.collect`<br>BloodHound collection (bloodhound-python) | `kali` | `bloodhound-python`; apt: bloodhound.py | **sample-only** — Only prints a sample; no domain/credential input or protected archive retrieval. |
| `ad.ldap.anon`<br>LDAP anonymous bind enum | `kali` | `ldapsearch`; apt: ldap-utils | **needs-validation** — Empty search base and fixed LDAP defaults; modern ldapsearch option compatibility and result-base discovery need validation. |

### bluetooth — 2 recipes

| Stable ID and title | Route | Declared tool / installer | Status and specific remaining work |
| --- | --- | --- | --- |
| `bt.scan.local`<br>Bluetooth scan (this Mac) | `local` | `system_profiler`; manual dependency | **known-defect** — system_profiler lists local Bluetooth state/known devices; it is not a general active scan of selected LAN device. |
| `bt.le.scan`<br>Bluetooth LE scan (hcitool) | `kali` | `hcitool`; apt: bluez | **needs-validation** — Linux adapter/privileges, obsolete hcitool support and target-independent capture scope need checks. |

### camera — 4 recipes

| Stable ID and title | Route | Declared tool / installer | Status and specific remaining work |
| --- | --- | --- | --- |
| `cam.onvif.probe`<br>ONVIF probe | `auto` | `nmap`; manual dependency | **known-defect** — Broadcast discovery is not constrained to the selected host; UDP privileges and NSE availability are unchecked. |
| `cam.hikvision.creds`<br>Hikvision default credentials | `auto` | `curl`; manual dependency | **needs-validation** — HTTP response code alone is not authenticated access; vendor paths/ports and lockout budget are unchecked. |
| `cam.rtsp.urls`<br>RTSP path bruteforce | `auto` | `curl`; manual dependency | **known-defect** — Declares curl but actually uses nc and timeout; default macOS lacks timeout. RTSP OPTIONS 200 does not prove a playable path. |
| `cam.snapshot`<br>Capture snapshot via ffmpeg | `kali` | `ffmpeg`; manual dependency | **needs-validation** — Hardcoded vendor stream path, no credential input, shared output file and no app-side artifact retrieval. |

### dns — 3 recipes

| Stable ID and title | Route | Declared tool / installer | Status and specific remaining work |
| --- | --- | --- | --- |
| `dns.zone-transfer`<br>DNS zone transfer (AXFR) | `auto` | `dig`; manual dependency | **needs-validation** — Reverse-DNS hostname is not a zone name; needs authorized zone input and DNS-service reachability. |
| `dns.dnsx.bruteforce`<br>Subdomain bruteforce (dnsx) | `kali` | `dnsx`; apt: dnsx | **known-defect** — Builds names from unvalidated reverse DNS; no explicit authorized domain or resolver configuration. |
| `dns.traceroute`<br>Path trace (mtr / traceroute) | `auto` | `mtr`; brew: mtr | **needs-validation** — mtr permissions and fallback availability are unchecked; failure inside pipes can hide fallback need. |

### exploit — 4 recipes

| Stable ID and title | Route | Declared tool / installer | Status and specific remaining work |
| --- | --- | --- | --- |
| `exploit.eternal.blue`<br>Check EternalBlue / MS17-010 | `auto` | `nmap`; manual dependency | **needs-validation** — NSE detection only; validate script/version and distinguish vulnerable, patched, unreachable and unknown. |
| `exploit.bluekeep`<br>Check BlueKeep / CVE-2019-0708 | `auto` | `nmap`; manual dependency | **known-defect** — Runs rdp-vuln-ms12-020, which checks a different vulnerability than BlueKeep/CVE-2019-0708. |
| `exploit.log4shell.probe`<br>Log4Shell probe (CVE-2021-44228) | `auto` | `curl`; manual dependency | **incomplete** — Sends marker requests but has no controlled callback/evidence channel; HTTP status cannot establish Log4Shell. |
| `exploit.shellshock`<br>Shellshock CGI probe (CVE-2014-6271) | `auto` | `curl`; manual dependency | **needs-validation** — Fixed CGI paths and marker matching need fixture validation; no separation of absent endpoint, transport error and unaffected target. |

### iot — 6 recipes

| Stable ID and title | Route | Declared tool / installer | Status and specific remaining work |
| --- | --- | --- | --- |
| `iot.mqtt.probe`<br>MQTT broker probe (1883/8883) | `auto` | `nmap`; manual dependency | **needs-validation** — NSE availability and subscription privacy scope need checks; advertised TLS ports do not imply authenticated/TLS coverage. |
| `iot.mqtt.subscribe`<br>MQTT subscribe-all (mosquitto_sub) | `kali` | `mosquitto_sub`; apt: mosquitto-clients, brew: mosquitto | **needs-validation** — Subscribes to every topic; needs approved topic scope, TLS/auth settings and protected output. Brew metadata is unused on forced-Kali route. |
| `iot.coap.discover`<br>CoAP discovery (5683) | `kali` | `coap-client`; apt: libcoap2-bin | **needs-validation** — Package/binary version compatibility, timeout behavior and structured resource parsing are unverified. |
| `iot.tplink.kasa`<br>TP-Link Kasa info (port 9999) | `auto` | `python3`; manual dependency | **known-defect** — One recv assumes a complete framed TCP response; legacy protocol only and no fragmented-response fixtures. |
| `iot.wol.wake`<br>Wake-on-LAN magic packet | `local` | `etherwake`; brew: wakeonlan | **known-defect** — Both branches receive target IP where a MAC is required; primary tool does not match brew-installed fallback. |
| `iot.zigbee.scan`<br>Zigbee / Z-Wave radio scan (ZGRAT) | `kali` | `whsniff`; apt: whsniff | **known-defect** — Title conflates Zigbee and Z-Wave; requires specific USB capture hardware and does not inspect selected IP. |

### media — 17 recipes

| Stable ID and title | Route | Declared tool / installer | Status and specific remaining work |
| --- | --- | --- | --- |
| `media.airplay.scan`<br>Scan for AirPlay receivers on this LAN | `local` | `atvremote`; manual dependency | **needs-validation** — LAN-wide discovery ignores selected device; pairing/protocol support and tool installation are not preflighted. |
| `media.airplay.sound`<br>Play sound on AirPlay receiver (this device) | `local` | `atvremote`; manual dependency | **needs-validation** — Hardcoded external clip, receiver pairing/support and actual fetch/playback are not verified. |
| `media.airplay.video`<br>Play video on AirPlay receiver | `local` | `atvremote`; manual dependency | **needs-validation** — Hardcoded external video; no file picker, codec negotiation or playback confirmation. |
| `media.cast.scan`<br>Scan for Chromecasts (catt scan) | `local` | `catt`; manual dependency | **needs-validation** — LAN-wide discovery is not selected-host execution; requires installed catt and multicast visibility. |
| `media.cast.video`<br>Cast video to Chromecast | `local` | `catt`; manual dependency | **needs-validation** — Hardcoded external video; no local-video selection, codec handling or confirmed rendering. |
| `media.airplay.localfile`<br>Play LOCAL audio file on AirPlay receiver | `local` | `python3`; manual dependency | **needs-validation** — Quoted selected-file runner has offline coverage; real AirPlay receivers, pairing and format support remain unverified. |
| `media.audio.smart`<br>SMART audio push (DLNA → AirPlay → Cast → Sonos) | `local` | `python3`; manual dependency | **limited-confirmation** — Historical maintainer/user confirmation covers one DLNA TV and one audio clip only. AirPlay/Cast/Sonos, other codecs and video are not confirmed. |
| `media.dlna.push`<br>DLNA push audio — TV / speaker renderer | `local` | `python3`; manual dependency | **needs-validation** — DLNA runner has loopback coverage and shares the historically confirmed SMART path; this specific UI action is not independently verified across receivers. |
| `media.bonjour.flood`<br>Bonjour service flood (visible names on every LAN Mac) | `local` | `dns-sd`; manual dependency | **known-defect** — Network-wide registrations, broad pkill and background children lack ownership-safe cleanup; observation label understates state changes. |
| `media.airplay.image`<br>Show image on Apple TV / AirPlay receiver | `local` | `atvremote`; brew: pyatv | **needs-validation** — Description says stream_file but command uses play_url; installed formula, receiver pairing and JPEG rendering need validation. |
| `media.airplay.tts`<br>Speak text on AirPlay receiver (TTS) | `local` | `say`; manual dependency | **known-defect** — Needs several undeclared tools; fixed HTTP port/interface assumptions and broad process cleanup are fragile. Text is hardcoded. |
| `media.cast.image`<br>Show image on Chromecast | `local` | `catt`; brew: catt | **needs-validation** — Description says cast_site but command uses cast; image rendering/tool formula and result confirmation remain unverified. |
| `media.cast.tts`<br>Speak text on Chromecast (Google TTS) | `local` | `catt`; manual dependency | **needs-validation** — Hardcoded message and undocumented external TTS endpoint; needs user text, dependency checks and playback evidence. |
| `media.cast.youtube`<br>Cast YouTube link to Chromecast | `local` | `catt`; manual dependency | **needs-validation** — Hardcoded external video; no URL input or receiver/application support check. |
| `media.dlna.discover`<br>Discover DLNA media renderers (gssdp) | `kali` | `gssdp-discover`; apt: gupnp-tools | **known-defect** — Kali route is declared but interface discovery uses BSD route syntax; selected target is ignored. |
| `media.bell`<br>Sonos doorbell chime (60 s) | `local` | `sonos`; brew: soco-cli | **needs-validation** — Title says 60 seconds but no duration/owned-stop logic exists; remote clip and CLI formula need verification. |
| `media.sonos.play`<br>Play sound on Sonos speaker | `local` | `sonos`; manual dependency | **needs-validation** — Hardcoded external clip; installed CLI, receiver compatibility and playback outcome are unverified. |

### mitm — 2 recipes

| Stable ID and title | Route | Declared tool / installer | Status and specific remaining work |
| --- | --- | --- | --- |
| `mitm.bettercap.recon`<br>Bettercap host recon (1 sweep) | `kali` | `bettercap`; apt: bettercap | **needs-validation** — Ignores selected host and scans executor LAN; raw-network privileges/interface and tool-version compatibility are not preflighted. |
| `mitm.dns.captive`<br>Captive portal DNS check | `auto` | `dig`; manual dependency | **needs-validation** — Measures executor connectivity and selected DNS server, not selected client Internet access; no reliable portal verdict. |

### mobile — 2 recipes

| Stable ID and title | Route | Declared tool / installer | Status and specific remaining work |
| --- | --- | --- | --- |
| `mobile.airdrop.beacon`<br>AirDrop beacon scan | `kali` | `hcitool`; manual dependency | **known-defect** — Generic BLE scan has no AirDrop decoder/classifier; title overstates what is detected. |
| `mobile.adb.connect`<br>ADB connect (Android dev port 5555) | `auto` | `adb`; brew: android-platform-tools | **needs-validation** — Requires enabled/pairable ADB; assumes legacy port 5555, lacks authorization/disconnect cleanup and structured device details. |

### password — 6 recipes

| Stable ID and title | Route | Declared tool / installer | Status and specific remaining work |
| --- | --- | --- | --- |
| `pwd.hashcat.wpa`<br>Crack WPA handshake with hashcat (rockyou) | `kali` | `hashcat`; apt: hashcat | **needs-validation** — Uses a shared pre-existing hash file/wordlist; no selected-network binding, artifact picker or hardware preflight. |
| `pwd.hashcat.shadow`<br>Crack /etc/shadow hashes (sha512crypt) | `kali` | `hashcat`; apt: hashcat | **needs-validation** — Fixed file path and hash mode; needs authorized hash input, format detection and protected output. |
| `pwd.hashcat.netntlm`<br>Crack NetNTLMv2 hashes (Responder output) | `kali` | `hashcat`; apt: hashcat | **known-defect** — Searches for session-log filenames rather than reliably selecting NetNTLMv2 hash records; artifact scope is not bound to target. |
| `pwd.hydra.http`<br>Hydra HTTP-form brute (top 100 passwords) | `kali` | `hydra`; apt: hydra | **sample-only** — Only prints a sample; no form/request/credential input or lockout controls. |
| `pwd.hashcat.test`<br>Hashcat self-test (sanity) | `kali` | `hashcat`; manual dependency | **needs-validation** — Benchmark rather than a full self-test; no compute-backend health interpretation. |
| `pwd.john.show`<br>John ‘show cracked’ snapshot | `kali` | `john`; manual dependency | **needs-validation** — Reads executor system shadow path; no authorized file input and privileges/results are ambiguous. |

### printer — 4 recipes

| Stable ID and title | Route | Declared tool / installer | Status and specific remaining work |
| --- | --- | --- | --- |
| `printer.pjl.banner`<br>PJL banner (raw 9100) | `auto` | `nc`; manual dependency | **known-defect** — Auto route can run on macOS, whose nc lacks Linux -q; timeout is also not a macOS base command. |
| `printer.ipp.attrs`<br>IPP attributes (port 631) | `kali` | `ipptool`; apt: cups-ipp-utils | **needs-validation** — IPP test-file location and fallback payload must be validated against a fixture; no parsed capability result. |
| `printer.test.page`<br>Print a test page (lpr) | `auto` | `lpr`; manual dependency | **known-defect** — References an unconfigured synthetic printer queue; print-server/queue selection is missing and can affect real hardware. |
| `printer.praeda`<br>PRAEDA (printer info harvest) | `kali` | `praeda`; apt: praeda | **needs-validation** — Tool/package/CLI compatibility and support data are unchecked; unstructured output does not establish findings. |

### recon — 10 recipes

| Stable ID and title | Route | Declared tool / installer | Status and specific remaining work |
| --- | --- | --- | --- |
| `recon.nmap.quick`<br>Quick port probe | `auto` | `nmap`; manual dependency | **needs-validation** — Confirm installed nmap version, reachability and service-result parsing; headless execution is not a completed scan report. |
| `recon.nmap.full`<br>Full TCP version scan (1–10000) | `auto` | `nmap`; manual dependency | **needs-validation** — First 10,000 ports only; description incorrectly gives an outside-range service as an example. |
| `recon.nmap.vuln`<br>NSE vuln scripts | `auto` | `nmap`; manual dependency | **needs-validation** — Review the selected NSE script set and per-script effects; validate findings rather than treating output as confirmed CVEs. |
| `recon.nuclei.basic`<br>Nuclei templates (CVEs + misconfigs) | `kali` | `nuclei`; manual dependency | **needs-validation** — No templates/version pin or template-update health; assumes HTTP on port 80. |
| `recon.searchsploit.banner`<br>Search Exploit-DB by version banner | `auto` | `searchsploit`; manual dependency | **needs-validation** — Also needs nmap and a local exploit database; banner extraction and search matching are fragile. |
| `recon.tlsscan`<br>TLS / SSL audit (testssl.sh) | `kali` | `testssl.sh`; manual dependency | **needs-validation** — Assumes HTTPS on default port; needs tool-version checks and actionable parsed findings. |
| `recon.theharvester`<br>OSINT email/domain harvest (theHarvester) | `kali` | `theHarvester`; apt: theharvester | **known-defect** — Reverse DNS is not an authorized domain boundary; example-domain fallback can query unrelated assets. |
| `recon.shodan.lookup`<br>Shodan lookup (external view) | `kali` | `shodan`; apt: shodan | **sample-only** — Only prints a sample; no API-key input or selected-public-host validation. Sample references executor public IP. |
| `recon.masscan`<br>Masscan all 65k ports (faster than nmap) | `kali` | `masscan`; apt: masscan | **needs-validation** — Root/raw-packet access and interface selection are not preflighted; piped fallback can mask failures. |
| `recon.rustscan`<br>Rustscan + nmap pipeline | `kali` | `rustscan`; apt: rustscan | **needs-validation** — Requires nmap as a second tool; no dependency or open-file-limit health check. |

### router — 4 recipes

| Stable ID and title | Route | Declared tool / installer | Status and specific remaining work |
| --- | --- | --- | --- |
| `router.creds.spray`<br>Default-credential sprayer (vendor cheatsheet) | `auto` | `curl`; manual dependency | **needs-validation** — Response/cookie heuristics can misidentify successful login; no lockout policy and fixed shared response files. |
| `router.default-accounts`<br>Default-credential sweep (nmap NSE) | `auto` | `nmap`; manual dependency | **needs-validation** — Fingerprint-file path assumes Linux even when auto resolves to macOS; results need vendor/version validation. |
| `router.snmp`<br>SNMP community check | `kali` | `onesixtyone`; manual dependency | **needs-validation** — Only legacy community-string discovery; shared wordlist and absent SNMP version/port controls. |
| `router.upnp`<br>UPnP enumeration | `kali` | `upnpc`; manual dependency | **known-defect** — Ignores selected IP; discovers the Kali execution network rather than reliably inspecting the selected router. |

### smb — 3 recipes

| Stable ID and title | Route | Declared tool / installer | Status and specific remaining work |
| --- | --- | --- | --- |
| `smb.netexec.enum`<br>Null-session SMB enum | `kali` | `netexec`; manual dependency | **needs-validation** — Anonymous SMB behavior, service compatibility and error/result parsing need fixtures. |
| `smb.smbclient.list`<br>List shares (anonymous) | `auto` | `smbclient`; manual dependency | **needs-validation** — Anonymous listing only; absent authentication must be reported as limited coverage. |
| `smb.netexec.spider`<br>Spider plus shares (auth required) | `kali` | `netexec`; manual dependency | **incomplete** — Title says authentication required but command sends empty credentials; no credential input or output-artifact retrieval. |

### ssh — 2 recipes

| Stable ID and title | Route | Declared tool / installer | Status and specific remaining work |
| --- | --- | --- | --- |
| `ssh.banner`<br>Banner + algos | `auto` | `nmap`; manual dependency | **needs-validation** — Assumes port 22 and installed NSE scripts; no selected-port or structured algorithm assessment. |
| `ssh.hydra.short`<br>Hydra small common-creds (4 users × 25 pwds) | `kali` | `hydra`; manual dependency | **needs-validation** — No lockout/rate-budget preflight; fixed shared temporary files and credential output require isolation/redaction. |

### web — 11 recipes

| Stable ID and title | Route | Declared tool / installer | Status and specific remaining work |
| --- | --- | --- | --- |
| `web.whatweb`<br>Fingerprint web stack | `auto` | `whatweb`; manual dependency | **needs-validation** — Assumes HTTP/default port; no scheme, TLS, virtual-host or structured fingerprint handling. |
| `web.nikto`<br>Nikto vulnerability scan | `auto` | `nikto`; manual dependency | **needs-validation** — No scan-policy selection, tuned service URL or structured finding validation. |
| `web.ffuf.dirs`<br>Directory bruteforce (top 1000 paths) | `kali` | `ffuf`; manual dependency | **needs-validation** — Fixed Linux wordlist is not checked; no wildcard-response calibration or selected service URL. |
| `web.feroxbuster`<br>Recursive directory scan (feroxbuster) | `kali` | `feroxbuster`; manual dependency | **needs-validation** — Fixed Linux wordlist and root URL; traversal budget and result semantics need validation. |
| `web.wpscan`<br>WordPress audit | `auto` | `wpscan`; manual dependency | **needs-validation** — Needs confirmed WordPress target, version pin and API/token handling for vulnerability coverage. |
| `web.sqlmap.basic`<br>SQL injection probe (sqlmap) | `kali` | `sqlmap`; manual dependency | **incomplete** — No parameter/request selection; testing only the root URL does not establish injection coverage. |
| `web.subfinder`<br>Subdomain enumeration (subfinder) | `kali` | `subfinder`; manual dependency | **known-defect** — Uses reverse-DNS hostname directly as a domain; missing public-domain input and scope validation. |
| `web.gobuster.vhost`<br>Virtual host bruteforce (gobuster vhost) | `kali` | `gobuster`; apt: gobuster | **known-defect** — Reverse-DNS/example-domain fallback may leave scope; fixed wordlist and domain must be explicit. |
| `web.dalfox.xss`<br>XSS scan (dalfox) | `kali` | `dalfox`; apt: dalfox | **incomplete** — Root URL only; needs explicit parameters/requests and evidence-based result handling. |
| `web.httpx.probe`<br>Live web fingerprint (httpx) | `kali` | `httpx`; apt: httpx-toolkit | **needs-validation** — Package/binary identity and version must be checked; scan results are unstructured text. |
| `web.gitleaks`<br>Test for exposed .git/.env (curl) | `auto` | `curl`; manual dependency | **needs-validation** — This is a curl path probe, not Gitleaks; HTTP 200/size does not prove exposed secrets. |

### wireless — 13 recipes

| Stable ID and title | Route | Declared tool / installer | Status and specific remaining work |
| --- | --- | --- | --- |
| `wifi.ultimate.psk`<br>🔥 ULTIMATE PSK recovery (PMKID + handshake + auto-crack) | `kaliRange` | `hashcat`; apt: aircrack-ng | **needs-validation** — Primary-tool installer does not cover the whole chain; fixed artifacts, tool-version drift, scope gates and cancellation cleanup remain unresolved. |
| `wifi.ultimate.wps`<br>🔥 ULTIMATE WPS recovery (pixie-dust → bully fallback) | `kaliRange` | `reaver`; apt: reaver | **needs-validation** — Bully/wash/iw dependencies are not fully checked; no reliable run ownership, cleanup or lockout/compatibility assessment. |
| `wifi.ultimate.bigwordlist`<br>🔥 ULTIMATE big-wordlist crack (88M words + rules) | `kaliRange` | `hashcat`; apt: hashcat | **known-defect** — Downloads gzip bytes into a .txt filename, then tries to decompress a nonexistent .txt.gz; unnecessary RF gate for offline cracking. |
| `wifi.ultimate.evil-twin`<br>🔥 ULTIMATE evil-twin captive portal (steal PSK from clients) | `kaliRange` | `wifiphisher`; apt: wifiphisher | **sample-only** — Prints manual instructions only; title/description overpromise an implemented end-to-end operation. Keep outside normal supported features. |
| `wifi.ultimate.client-map`<br>🔥 ULTIMATE client+AP map (5-min channel walk) | `kaliRange` | `airodump-ng`; apt: aircrack-ng | **needs-validation** — Unselected broad RF capture and shared files; versioned CSV parser, privacy boundaries and cleanup need review. |
| `wifi.ultimate.deauth-storm`<br>🔥 ULTIMATE deauth storm (mdk4 amok mode — full LAN DoS) | `kaliRange` | `mdk4`; apt: mdk4 | **scope-blocked** — Does not filter by selected BSSID and can affect unrelated nearby networks. Keep unavailable; do not present as a supported community feature. |
| `wifi.iw.list`<br>List Kali wireless interfaces | `kaliRange` | `iw`; manual dependency | **needs-validation** — Inventory should not require a Wi-Fi target or RF-range confirmation; Linux-only route must be explicit. |
| `wifi.airodump.scan`<br>airodump-ng — capture nearby APs + clients | `kaliRange` | `airodump-ng`; apt: aircrack-ng | **needs-validation** — Incomplete noninteractive sudo handling, monitor-mode fallback, shared artifact cleanup and broad-capture boundaries. |
| `wifi.handshake.capture`<br>WPA handshake capture (deauth + airodump) | `kaliRange` | `aireplay-ng`; apt: aircrack-ng | **needs-validation** — Secondary converter missing from install metadata; shared artifacts and background child cleanup lack per-run ownership. |
| `wifi.pmkid.attack`<br>WPA PMKID attack (hcxdumptool) | `kaliRange` | `hcxdumptool`; apt: hcxdumptool | **needs-validation** — Operates on a managed interface; tool-version options, converter dependency, connectivity preservation and artifact ownership are unchecked. |
| `wifi.deauth.broadcast`<br>Deauth burst (aireplay-ng -0) | `kaliRange` | `aireplay-ng`; apt: aircrack-ng | **needs-validation** — Selected BSSID is present but channel-setting/PMF capability checks and reliable cancellation/cleanup are absent. |
| `wifi.rogue.eaphammer`<br>Evil-twin / rogue AP (eaphammer) | `kaliRange` | `eaphammer`; apt: eaphammer | **sample-only** — Only prints manual setup; interactive session lifecycle and authorized scope are not implemented. |
| `wifi.wps.pixie`<br>WPS pixie-dust attack | `kaliRange` | `reaver`; manual dependency | **needs-validation** — Version/device support, complete dependency preflight and owned monitor cleanup need validation. |

## Non-Arsenal app actions

These are source-reviewed action groups, not additional Arsenal recipes. They are included so the catalog count cannot be mistaken for total app readiness.

| Action | Remaining work / limits | Sources |
| --- | --- | --- |
| Engage / Stop / automatic new-target reconciliation | Implemented IPv4 peer targeting; complete Internet denial across IPv6, isolation and protected peers is not established. Stop currently announces idle before cleanup completes; restoration failures may be suppressed by generation checks. | `App/State/AppCoordinator.swift`, `Helper/Sources/Service/HelperService.swift` |
| Trust / untrust and profiles | MAC-based allowlists and JSON profile persistence exist. Validate persistence failures, duplicate SSIDs, network identity changes and randomized MAC behavior; metadata is not identity proof. | `App/State/AppStore.swift`, `App/Features/Profiles/ProfilesView.swift` |
| Continuous device discovery / identity / Lobby / Recon | Discovery/enrichment exists. Missed peers remain retained without reliable departure/return state; not all observations imply current reachability. Unknown devices must remain unknown. Coverage and UI consistency need fixtures and bounded expiry. | `App/State/AppCoordinator.swift`, `App/State/AppStore.swift`, `App/State/UPnPDiscovery.swift`, `App/State/MDNSAppEnricher.swift` |
| Throughput / speed test | Throughput counts observable frames, not all LAN traffic or accurate per-device Internet upload/download. Speed-test failures collapse to zero and HTTP status is not validated. TCP-connect failures are not ICMP packet loss. | `App/State/AppCoordinator.swift`, `Helper/CSources/wm_pcap.c`, `Helper/Sources/Speed/SpeedTester.swift` |
| Nearby Wi-Fi scan / Join / Disconnect / hidden network | Actions exist; OS permissions, unavailable scan context, confirmed post-join network identity and error reporting need acceptance coverage. Do not infer empty results prove AP isolation. | `App/Features/NetworkPicker/NetworksView.swift`, `Helper/Sources/WiFi/WiFiManager.swift` |
| Saved-password reveal / forget / recovery suggestions | Keychain/password actions and candidate suggestions exist. Vendor/default candidates are hypotheses, not recovered passwords. Verify secure handling and actual join outcome; RF recovery handoffs inherit unfinished catalog work. | `App/Features/NetworkPicker/NetworksView.swift`, `App/Features/NetworkPicker/PasswordRecoverySheet.swift`, `App/State/WiFiPasswordRecovery.swift` |
| Schedule | UI persists days/hours/enabled state. No schedule execution consumer was found in AppCoordinator/helper; automatic enforcement is unfinished. Time zones, overnight ranges, sleep/wake and explicit scope gates remain undecided. | `App/Features/Profiles/ScheduleView.swift`, `Shared/Sources/Models/Profile.swift` |
| Helper install / connect / reinstall / ping / quit | Authenticated helper path and exact personal-build signature pin exist. No app/helper protocol version negotiation; reinstall/upgrade/rollback and reconnection snapshots need release tests. Admin approval is expected; Connected alone does not establish engine health. | `App/State/HelperClient.swift`, `Scripts/install-helper.sh`, `Shared/Sources/Protocols/HelperProtocol.swift` |
| New-device notifications / menu bar / onboarding | New-device notifications exist; departure/return history is incomplete. Validate permission denial, deduplication, menu-bar/app state agreement and small-window accessibility without triggering real actions. | `App/State/AppStore.swift`, `App/Features/MenuBar/MenuBarPanel.swift`, `App/Features/Onboarding/OnboardingView.swift` |
| Automatic bandwidth-hog blocking / block modes | Bandwidth-hog toggle/threshold are stored, but no enforcement consumer was found. Stealth sampling exists in ARPSpoofer; its end-to-end behavior with the active responder and accurate traffic measurements needs verification. Do not describe either as confirmed QoS. | `App/Features/Profiles/ProfilesView.swift`, `Shared/Sources/Models/Profile.swift`, `Helper/Sources/Spoof/ARPSpoofer.swift` |

## Contribution acceptance

A command can leave this list only when its supported platform, exact target/scope, required inputs, dependency versions, cancellation/cleanup and outcome evidence are documented and tested. Use isolated fixtures first. Real-device/RF/disruption/media tests require explicit owner authorization; do not run the entire catalog as an automated test suite. Redact private addresses, identifiers, credentials and output artifacts from issues.

For sample-only and scope-blocked entries, a clear unavailable/unsupported UI state or removal can be a better contribution than expanding the operation. Do not equate a process exit code with success or promise universal router/device support.

## Audit method

- Parsed every `Attack(...)` catalog entry and reconciled 99 unique IDs with category, route and status totals.
- Read shared template expansion, Arsenal dispatch/authorization, local/SSH execution, range preflight and bundled audio runner.
- Reviewed existing loopback media and literal-argument test sources; no tests or commands were dispatched as part of this source inventory.
- Checked each entry for missing inputs/dependencies, selected-target mismatches, platform assumptions, output semantics and cleanup risks.
- Source hashes and static reconciliation establish inventory completeness, not operational compatibility.
