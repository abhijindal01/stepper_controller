# Reaching the dashboard by name

The dashboard listens on `0.0.0.0:5000`, so it answers to **any** name or
address that resolves to the Pi:

| How you open it | Works on | Needs |
|---|---|---|
| `http://assurance.local:5000` | same LAN, mDNS-capable client | avahi on the Pi, client mDNS |
| `http://192.168.0.148:5000` | anything on the LAN | nothing (but the IP can change) |
| `http://100.91.116.80:5000` | anywhere on the Tailscale tailnet | Tailscale on both ends |
| `http://assurance:5000` | LAN, if your router serves DNS for it | router/DHCP DNS entry |

`server.py` prints the first two at startup:

```
Dashboard: http://assurance.local:5000/
Dashboard: http://192.168.0.148:5000/
Serving with waitress on 0.0.0.0:5000 (8 threads)
```

Check everything at once:

```bash
bash tools/diagnose.sh
```

---

## 1. Set the name up on the Pi (once)

```bash
cd /home/quality/stepper_controller
sudo bash tools/setup_hostname.sh --dry-run            # see what it would do
sudo bash tools/setup_hostname.sh                      # keep the current name
sudo bash tools/setup_hostname.sh --hostname assurance # or rename
```

It sets the hostname, keeps `/etc/hosts` consistent, installs and starts
`avahi-daemon`, advertises `_http._tcp` on port 5000 (so the dashboard shows up
in Bonjour browsing), opens the port if `ufw` is active, and then verifies with
`getent hosts`, `avahi-resolve` and `curl`.

Manual equivalent:

```bash
sudo apt-get install -y avahi-daemon libnss-mdns avahi-utils
sudo systemctl enable --now avahi-daemon
avahi-resolve -n $(hostname -s).local
```

---

## 2. "This site can't be reached — DNS_PROBE_FINISHED_NXDOMAIN"

That error means **the client never resolved the name**; the Pi was never
contacted. The service can be perfectly healthy (check with
`curl http://127.0.0.1:5000/login` on the Pi).

### Windows

1. **Chrome's "secure DNS" bypasses mDNS.** Chrome → Settings → Privacy and
   security → Security → turn **off** *Use secure DNS*. Retest. (Edge/Firefox
   have equivalents.)
2. **Check the OS can resolve it** — if this works, it is a browser setting:

   ```powershell
   ping assurance.local
   nslookup assurance.local
   ```

3. **Static entry (always works, survives browser quirks).** Open Notepad **as
   Administrator**, edit `C:\Windows\System32\drivers\etc\hosts` and add:

   ```
   192.168.0.148   assurance.local assurance
   ```

   Give the Pi a **DHCP reservation** so that address never changes.

### Linux / macOS

```bash
ping assurance.local          # macOS resolves this natively
avahi-resolve -n assurance.local
sudo apt install libnss-mdns  # Debian/Ubuntu client
```

### Why it can fail even with everything set

* **Client isolation / guest Wi-Fi** — the router blocks device-to-device
  traffic. Fix in the router, or use the IP.
* **VPN** (Tailscale included) may take over DNS or route `.local` traffic
  away. Use the tailnet name/IP instead.
* **Two subnets / VLANs** — mDNS is link-local; it does not cross routers.

---

## 3. Prefer real DNS to mDNS

If the router (or a local DNS server) can hold a static entry, do that —
`http://assurance:5000` then works for every client without mDNS:

* Router admin → *Local DNS* / *Static DNS* → `assurance` → the Pi's IP.
* Or add to the router's DHCP reservation list and publish the hostname.
* Pi-hole / dnsmasq on the LAN: add `address=/assurance/192.168.0.148`.

---

## 4. Access from outside the LAN

Tailscale is already on this Pi (`100.91.116.80`). Either use that IP, or turn
on **MagicDNS** in the tailnet settings and use the machine name:

```
http://assurance.<your-tailnet>.ts.net:5000
```

Change the hostname with `sudo tailscale set --hostname assurance` if the
tailnet name differs from the system hostname.

---

## 5. Quick reference

```bash
hostname -s                     # the name
hostname -I                     # the addresses
avahi-resolve -n $(hostname -s).local
getent hosts $(hostname -s).local
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5000/login
bash tools/diagnose.sh          # all of the above, plus service/USB/heat state
```
