# Security hardening steps

Sprache wählen / Choose a language

<details open name="language">
<summary><b>Deutsch</b></summary>

`scripts/setup.sh` wendet jeden dieser Schritte an. `scripts/verify.sh` prüft die wichtigsten.

## 1. System

| Maßnahme | Warum | Wo |
|---|---|---|
| Paketlisten und installierte Pakete aktualisiert | schließt bekannte Sicherheitslücken, bevor etwas erreichbar ist | `setup.sh`, Schritt 1 |
| Nur nötige Pakete installiert (nginx, ufw, fail2ban, unattended-upgrades, openssl, curl) | jedes zusätzliche Paket vergrößert die Angriffsfläche | `setup.sh`, Schritt 2 |
| Automatische Sicherheitsupdates aktiviert | neue Patches werden ohne Zutun eingespielt | `/etc/apt/apt.conf.d/20auto-upgrades` |
| Webverzeichnis gehört root, Dateien 644, Ordner 755 | ein Fehler in Nginx kann die Seite nicht verändern, der Nginx-Benutzer `www-data` darf nur lesen | `/var/www/secure-site` |

## 2. Firewall (UFW)

| Maßnahme | Warum | Wo |
|---|---|---|
| Standard: eingehend verwerfen, ausgehend erlauben, Weiterleitung verwerfen | alles, was nicht erlaubt ist, wird verworfen | `firewall/ufw-setup.sh` |
| 80/tcp und 443/tcp erlaubt | der Webserver | `firewall/ufw-setup.sh` |
| 22/tcp erlaubt mit `ufw limit` | SSH bleibt erreichbar, eine Adresse mit 6 oder mehr Verbindungsversuchen in 30 Sekunden wird blockiert | `firewall/ufw-setup.sh` |
| SSH-Regel vor dem Aktivieren der Firewall | sonst bricht die laufende SSH-Sitzung ab und man sperrt sich aus | `firewall/ufw-setup.sh` |
| Logging auf `low` | blockierte Pakete erscheinen in `/var/log/ufw.log` | `firewall/ufw-setup.sh` |

## 3. SSH

| Maßnahme | Warum | Wo |
|---|---|---|
| `PermitRootLogin no` | das Root-Konto kann nicht direkt angegriffen werden | `ssh/10-hardening.conf` |
| `MaxAuthTries 3` | wenige Versuche pro Verbindung | `ssh/10-hardening.conf` |
| `LoginGraceTime 30` | unfertige Anmeldungen werden nach 30 Sekunden getrennt | `ssh/10-hardening.conf` |
| `PermitEmptyPasswords no` | Konten ohne Passwort können sich nicht anmelden | `ssh/10-hardening.conf` |
| `X11Forwarding no`, `AllowAgentForwarding no` | nicht benötigte Funktionen sind abgeschaltet | `ssh/10-hardening.conf` |
| `ClientAliveInterval 300`, `ClientAliveCountMax 2` | Leerlauf-Sitzungen enden nach etwa 10 Minuten | `ssh/10-hardening.conf` |
| `LogLevel VERBOSE` | im Log steht, mit welchem Schlüssel sich jemand angemeldet hat | `ssh/10-hardening.conf` |
| Optional: Passwort-Login aus (`--disable-ssh-passwords`) | Schlüssel lassen sich nicht durch Raten knacken; das Skript prüft vorher, ob ein Schlüssel hinterlegt ist | `ssh/11-disable-password-auth.conf` |

## 4. Nginx

| Maßnahme | Warum | Wo |
|---|---|---|
| `server_tokens off` | die Nginx-Version steht weder im Header noch auf Fehlerseiten | `nginx/nginx.conf` |
| Zeitlimits und Größenlimits (`client_header_timeout`, `client_body_timeout`, `client_max_body_size 1m`) | schützt vor langsamen Clients und übergroßen Anfragen | `nginx/nginx.conf` |
| Ratenbegrenzung: 10 Anfragen pro Sekunde und IP (Burst 20), höchstens 20 gleichzeitige Verbindungen pro IP | bremst Missbrauch | `nginx/sites-available/secure-site.conf` |
| HTTP leitet mit 301 auf HTTPS um | kein Verkehr im Klartext | `nginx/sites-available/secure-site.conf` |
| Nur GET und HEAD erlaubt, alles andere liefert 403 | eine statische Seite braucht nichts anderes | `nginx/sites-available/secure-site.conf` |
| Versteckte Dateien (`.git`, `.env`) und Sicherungsdateien (`.bak`, `.old`, `.sql`, ...) liefern 404 | verhindert versehentlich veröffentlichte Daten | `nginx/sites-available/secure-site.conf` |
| Sicherheits-Header: HSTS, `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`, `Permissions-Policy`, `Content-Security-Policy` | Schutz im Browser vor Clickjacking, MIME-Sniffing und fremden Inhalten | `nginx/snippets/security-headers.conf` |
| Standardseite von Nginx entfernt | keine Standardseite, die den Server verrät | `setup.sh`, Schritt 5 |
| Eigene Access- und Error-Logs für die Seite | getrennte Auswertung, und fail2ban liest das Error-Log | `nginx/sites-available/secure-site.conf` |

## 5. TLS

| Maßnahme | Warum | Wo |
|---|---|---|
| Nur TLS 1.2 und 1.3 | ältere Versionen haben bekannte Schwächen | `nginx/snippets/ssl-params.conf` |
| Nur ECDHE-Suiten mit AES-GCM und ChaCha20 | Forward Secrecy und moderne Verschlüsselung | `nginx/snippets/ssl-params.conf` |
| Session-Tickets aus | Sitzungsschlüssel werden nicht länger als nötig aufbewahrt | `nginx/snippets/ssl-params.conf` |
| Selbst signiertes EC-Zertifikat (P-256) mit den IP-Adressen der VM | HTTPS funktioniert im Lab ohne Domain | `setup.sh`, Schritt 4 |
| Privater Schlüssel mit Rechten 600, Besitzer root | andere Benutzer können ihn nicht lesen | `/etc/ssl/private/secure-site.key` |

## 6. fail2ban

| Maßnahme | Warum | Wo |
|---|---|---|
| Jail `sshd`: 3 Fehlversuche in 10 Minuten ergeben 1 Stunde Sperre | bremst Passwort-Raten | `fail2ban/jail.local` |
| Jail `nginx-limit-req`: 10 Treffer der Ratenbegrenzung ergeben 1 Stunde Sperre | sperrt Clients, die ständig das Limit überschreiten | `fail2ban/jail.local` |
| `ignoreip` enthält localhost und den Windows-Host `192.168.56.1` | man sperrt sich bei Tests nicht selbst aus | `fail2ban/jail.local` |

## Was nicht abgedeckt ist

- Das Zertifikat ist selbst signiert. Mit einer echten Domain käme ein Let's-Encrypt-Zertifikat mit OCSP-Stapling dazu.
- Ausgehender Verkehr ist erlaubt, weil `apt` ihn braucht.
- Ping (ICMP) wird beantwortet, weil UFW das standardmäßig erlaubt. Wer das nicht will, ändert `/etc/ufw/before.rules`.
- Es gibt keine Einbruchserkennung, keine zentrale Log-Auswertung und keine Backups.
- AppArmor bleibt auf den Standardwerten von Ubuntu.
- Das Ganze läuft in einem privaten Lab-Netz. Ein Server im Internet braucht zusätzlich Überwachung und Backups.

## Stolperfallen

- sshd verwendet für jede Option den ersten gelesenen Wert, und die Dateien in `/etc/ssh/sshd_config.d/` werden alphabetisch gelesen. Deshalb beginnen die Dateinamen mit 10 und 11. Cloud-Images bringen oft `50-cloud-init.conf` mit `PasswordAuthentication yes` mit, das sonst gewinnen würde. Prüfen mit `sudo sshd -T | grep -i passwordauthentication`.
- In Nginx ersetzt ein `add_header` in einem `location`-Block alle Header, die vom `server`-Block geerbt werden. Deshalb stehen alle Header auf Server-Ebene.
- Ubuntu nutzt für fail2ban standardmäßig das systemd-Journal als Backend. Der Jail `nginx-limit-req` liest aber eine Datei und braucht deshalb `backend = auto`, sonst bannt er nie.
- `ufw enable` über SSH ohne SSH-Regel trennt die Verbindung.

</details>

<details name="language">
<summary><b>English</b></summary>

`scripts/setup.sh` applies every step below. `scripts/verify.sh` checks the main ones.

## 1. System

| Measure | Why | Where |
|---|---|---|
| Package lists and installed packages updated | closes known vulnerabilities before anything is exposed | `setup.sh`, step 1 |
| Only the needed packages installed (nginx, ufw, fail2ban, unattended-upgrades, openssl, curl) | every extra package adds attack surface | `setup.sh`, step 2 |
| Automatic security updates enabled | new patches install without anyone doing anything | `/etc/apt/apt.conf.d/20auto-upgrades` |
| Web root owned by root, files 644, directories 755 | a bug in Nginx cannot change the site, the Nginx user `www-data` can only read | `/var/www/secure-site` |

## 2. Firewall (UFW)

| Measure | Why | Where |
|---|---|---|
| Default: deny incoming, allow outgoing, deny routed | anything not explicitly allowed is dropped | `firewall/ufw-setup.sh` |
| 80/tcp and 443/tcp allowed | the web server | `firewall/ufw-setup.sh` |
| 22/tcp allowed with `ufw limit` | SSH stays reachable, an address with 6 or more connection attempts in 30 seconds is blocked | `firewall/ufw-setup.sh` |
| SSH rule added before the firewall is enabled | otherwise the running SSH session drops and you lock yourself out | `firewall/ufw-setup.sh` |
| Logging set to `low` | blocked packets show up in `/var/log/ufw.log` | `firewall/ufw-setup.sh` |

## 3. SSH

| Measure | Why | Where |
|---|---|---|
| `PermitRootLogin no` | the root account cannot be attacked directly | `ssh/10-hardening.conf` |
| `MaxAuthTries 3` | few guesses per connection | `ssh/10-hardening.conf` |
| `LoginGraceTime 30` | unfinished logins are dropped after 30 seconds | `ssh/10-hardening.conf` |
| `PermitEmptyPasswords no` | accounts without a password cannot log in | `ssh/10-hardening.conf` |
| `X11Forwarding no`, `AllowAgentForwarding no` | features that are not needed are off | `ssh/10-hardening.conf` |
| `ClientAliveInterval 300`, `ClientAliveCountMax 2` | idle sessions end after about 10 minutes | `ssh/10-hardening.conf` |
| `LogLevel VERBOSE` | the log shows which key was used to log in | `ssh/10-hardening.conf` |
| Optional: password login off (`--disable-ssh-passwords`) | keys cannot be guessed by brute force; the script first checks that a key is installed | `ssh/11-disable-password-auth.conf` |

## 4. Nginx

| Measure | Why | Where |
|---|---|---|
| `server_tokens off` | the Nginx version is not shown in headers or on error pages | `nginx/nginx.conf` |
| Timeouts and size limits (`client_header_timeout`, `client_body_timeout`, `client_max_body_size 1m`) | protects against slow clients and oversized requests | `nginx/nginx.conf` |
| Rate limit: 10 requests per second per IP (burst 20), at most 20 open connections per IP | slows down abuse | `nginx/sites-available/secure-site.conf` |
| HTTP redirects to HTTPS with 301 | no traffic in plain text | `nginx/sites-available/secure-site.conf` |
| Only GET and HEAD allowed, everything else returns 403 | a static site needs nothing else | `nginx/sites-available/secure-site.conf` |
| Hidden files (`.git`, `.env`) and backup files (`.bak`, `.old`, `.sql`, ...) return 404 | stops accidentally published data | `nginx/sites-available/secure-site.conf` |
| Security headers: HSTS, `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`, `Permissions-Policy`, `Content-Security-Policy` | browser-side protection against clickjacking, MIME sniffing and foreign content | `nginx/snippets/security-headers.conf` |
| Nginx default site removed | no default page that gives the server away | `setup.sh`, step 5 |
| Separate access and error logs for the site | easier to read, and fail2ban reads the error log | `nginx/sites-available/secure-site.conf` |

## 5. TLS

| Measure | Why | Where |
|---|---|---|
| TLS 1.2 and 1.3 only | older versions have known weaknesses | `nginx/snippets/ssl-params.conf` |
| ECDHE suites with AES-GCM and ChaCha20 only | forward secrecy and modern encryption | `nginx/snippets/ssl-params.conf` |
| Session tickets off | session keys are not kept longer than needed | `nginx/snippets/ssl-params.conf` |
| Self-signed EC certificate (P-256) with the VM's IP addresses | HTTPS works in the lab without a domain | `setup.sh`, step 4 |
| Private key with mode 600, owned by root | other users cannot read it | `/etc/ssl/private/secure-site.key` |

## 6. fail2ban

| Measure | Why | Where |
|---|---|---|
| Jail `sshd`: 3 failed logins in 10 minutes give a 1 hour ban | slows down password guessing | `fail2ban/jail.local` |
| Jail `nginx-limit-req`: 10 rate-limit hits give a 1 hour ban | bans clients that keep going over the limit | `fail2ban/jail.local` |
| `ignoreip` contains localhost and the Windows host `192.168.56.1` | you do not lock yourself out while testing | `fail2ban/jail.local` |

## What this does not cover

- The certificate is self-signed. With a real domain, a Let's Encrypt certificate with OCSP stapling would come next.
- Outgoing traffic is allowed because `apt` needs it.
- Ping (ICMP) is answered because UFW allows it by default. To block it, edit `/etc/ufw/before.rules`.
- There is no intrusion detection, central log analysis or backup.
- AppArmor stays at the Ubuntu defaults.
- It runs in a private lab network. A server on the internet needs monitoring and backups on top.

## Things to watch out for

- sshd uses the first value it reads for each option, and the files in `/etc/ssh/sshd_config.d/` are read in alphabetical order. That is why the file names start with 10 and 11. Cloud images often ship `50-cloud-init.conf` with `PasswordAuthentication yes`, which would win otherwise. Check with `sudo sshd -T | grep -i passwordauthentication`.
- In Nginx, an `add_header` inside a `location` block replaces every header inherited from the `server` block. That is why all headers sit at server level.
- On Ubuntu, fail2ban uses the systemd journal as its default backend. The `nginx-limit-req` jail reads a file, so it needs `backend = auto`, otherwise it never bans anyone.
- Running `ufw enable` over SSH without an SSH rule cuts the connection.

</details>
