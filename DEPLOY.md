# Deployment on the MikroTik L009

Reference for how the `ghcr.io/jr551/angie:armv7` image is wired up as a public-facing
reverse proxy on `jr551@192.168.69.1`. All paths and IPs reflect the live setup.

## Layout

| Thing               | Value                                                       |
| ------------------- | ----------------------------------------------------------- |
| Container name      | `angie`                                                     |
| veth                | `veth-angie` (172.31.0.10/24, gateway 172.31.0.1)           |
| Bridge              | `containers`                                                |
| Root dir on SSD     | `/samsungssd2tb/container-root/angie`                       |
| Config/data on SSD  | `/samsungssd2tb/container-root/angie-deploy/`               |
| Public hostname     | `hfd09d4n3be.sn.mynetname.net` (MikroTik DDNS → 89.35.197.169) |
| Cert lives on       | `/samsungssd2tb/container-root/angie-deploy/certs/`         |
| ACME client         | `~/.acme.sh/` on the user's Mac (cron-driven daily)         |

## SSD layout

```
/samsungssd2tb/container-root/
├── angie/                       # container root (RouterOS-managed)
└── angie-deploy/
    ├── conf/angie.conf          # mounted to /etc/angie/angie.conf
    ├── html/index.html          # mounted to /usr/share/angie/html/
    └── certs/
        ├── cert.pem             # fullchain (Let's Encrypt)
        └── key.pem              # private key
```

The `angie-deploy/` files are owned by you, not by RouterOS — edit them, then either
SIGHUP angie (not currently easy from RouterOS shell) or stop+start the container to reload.

## Recreating the deployment from scratch

If you ever blow away the container and need to recreate it:

### 1. Make sure the deploy files exist on the SSD

```sh
# On the Mac:
scp -O ~/angie-deploy/conf/angie.conf  jr551@192.168.69.1:/samsungssd2tb/container-root/angie-deploy/conf/angie.conf
scp -O ~/angie-deploy/html/index.html  jr551@192.168.69.1:/samsungssd2tb/container-root/angie-deploy/html/index.html
# certs come from acme.sh — see "Certificate" section below
```

(The `~/angie-deploy/` source dir on the Mac mirrors what's on the router.
If lost, re-create from the snippets in this doc.)

### 2. Create the veth, bridge port, and mounts on the router

```routeros
/interface/veth/add name=veth-angie address=172.31.0.10/24 gateway=172.31.0.1
/interface/bridge/port/add bridge=containers interface=veth-angie

/container/mounts/add list=angie_conf  src=/samsungssd2tb/container-root/angie-deploy/conf/angie.conf  dst=/etc/angie/angie.conf
/container/mounts/add list=angie_html  src=/samsungssd2tb/container-root/angie-deploy/html             dst=/usr/share/angie/html
/container/mounts/add list=angie_certs src=/samsungssd2tb/container-root/angie-deploy/certs            dst=/etc/angie/certs
```

### 3. Add the container

```routeros
/container/add \
  remote-image=ghcr.io/jr551/angie:armv7 \
  interface=veth-angie \
  root-dir=/samsungssd2tb/container-root/angie \
  name=angie \
  mountlists=angie_conf,angie_html,angie_certs \
  dns=1.1.1.1 \
  hostname=angie \
  start-on-boot=yes \
  logging=yes
```

Wait for the `E` (downloading/extracting) flag to clear to `S` (stopped), then:

```routeros
/container/start [find name=angie]
```

### 4. NAT — publish 80/443

```routeros
/ip/firewall/nat/add chain=dstnat action=dst-nat protocol=tcp \
  in-interface-list=WAN dst-port=80 \
  to-addresses=172.31.0.10 to-ports=80 \
  comment="Angie HTTP WAN"

/ip/firewall/nat/add chain=dstnat action=dst-nat protocol=tcp \
  dst-address-list=WANs in-interface=lanbridge1-home dst-port=80 \
  to-addresses=172.31.0.10 \
  comment="Angie HTTP hairpin"

/ip/firewall/nat/add chain=dstnat action=dst-nat protocol=tcp \
  in-interface-list=WAN dst-port=443 \
  to-addresses=172.31.0.10 to-ports=443 \
  comment="Angie HTTPS WAN"

/ip/firewall/nat/add chain=dstnat action=dst-nat protocol=tcp \
  dst-address-list=WANs in-interface=lanbridge1-home dst-port=443 \
  to-addresses=172.31.0.10 \
  comment="Angie HTTPS hairpin"
```

The container's outbound traffic is already covered by the existing
`172.31.0.0/24` masquerade rule (commented "Tailscale container outbound").

The previous `.16.100` HTTPS rules (rules 3–6 in `/ip/firewall/nat/print` at the
time of the migration) are **disabled, not deleted** — re-enable them only after
removing or moving the Angie rules first, otherwise dst-port 443 is ambiguous.

## Reference: angie.conf

```nginx
user  angie;
worker_processes  auto;
error_log  /var/log/angie/error.log notice;
pid        /var/run/angie.pid;

events { worker_connections 1024; }

http {
    include       /etc/angie/mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    keepalive_timeout  65;
    server_tokens off;
    access_log /var/log/angie/access.log;

    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        server_name _;
        root  /usr/share/angie/html;
        index index.html;

        # ACME http-01 stateless validation
        location ~ "^/\.well-known/acme-challenge/([-_a-zA-Z0-9]+)$" {
            default_type text/plain;
            return 200 "$1.<ACCOUNT_THUMBPRINT>";
        }
    }

    server {
        listen 443 ssl default_server;
        listen [::]:443 ssl default_server;
        http2 on;
        server_name _;

        ssl_certificate     /etc/angie/certs/cert.pem;
        ssl_certificate_key /etc/angie/certs/key.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;

        root  /usr/share/angie/html;
        index index.html;
    }
}
```

`<ACCOUNT_THUMBPRINT>` is the acme.sh account thumbprint — see below.

To make this an actual reverse proxy (rather than just hello-world), replace the
`root`/`index` lines in the 443 server with a `location / { proxy_pass http://...; }`
block pointing at the upstream service. Standard nginx syntax.

## Certificate — Let's Encrypt via acme.sh

Issued and renewed on the Mac (`~/.acme.sh/`), pushed to the router via SCP.

### How it was issued (one-time)

```sh
# Install acme.sh, register an account, capture the thumbprint:
curl https://get.acme.sh | sh -s email=john.rowe@whitespacews.com
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --register-account -m john.rowe@whitespacews.com
# Note the printed ACCOUNT_THUMBPRINT — paste it into angie.conf
# (the location block under server :80 above), then push the conf and restart angie.

~/.acme.sh/acme.sh --issue --stateless -d hfd09d4n3be.sn.mynetname.net
```

`--stateless` mode means acme.sh never has to write challenge files anywhere — angie
computes the response on the fly from the URL and the embedded thumbprint. No webroot
syncing required.

### Renewal (automatic)

acme.sh installed a daily cron job during install. Renewal happens within ~30 days
of expiry. After a successful renew, the `--install-cert --reloadcmd` runs to push
the new cert to the router and bounce the container:

```sh
~/.acme.sh/acme.sh --install-cert -d hfd09d4n3be.sn.mynetname.net --ecc \
  --fullchain-file ~/.acme.sh/deployed/hfd09d4n3be-fullchain.pem \
  --key-file       ~/.acme.sh/deployed/hfd09d4n3be-key.pem \
  --reloadcmd 'scp -O ~/.acme.sh/deployed/hfd09d4n3be-fullchain.pem jr551@192.168.69.1:/samsungssd2tb/container-root/angie-deploy/certs/cert.pem \
            && scp -O ~/.acme.sh/deployed/hfd09d4n3be-key.pem       jr551@192.168.69.1:/samsungssd2tb/container-root/angie-deploy/certs/key.pem \
            && ssh jr551@192.168.69.1 "/container/stop [find name=angie]" \
            && sleep 3 \
            && ssh jr551@192.168.69.1 "/container/start [find name=angie]"'
```

> **Note:** the live install currently uses `number=2` instead of `[find name=angie]`.
> If containers are added/removed and indexes shift, update the install with the
> command above (which is index-stable).

### Force a renew now

```sh
~/.acme.sh/acme.sh --renew --force --ecc -d hfd09d4n3be.sn.mynetname.net
```

### Verify

```sh
echo | openssl s_client -connect hfd09d4n3be.sn.mynetname.net:443 \
  -servername hfd09d4n3be.sn.mynetname.net 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
```

## Operating

| Task                         | Command                                                                  |
| ---------------------------- | ------------------------------------------------------------------------ |
| Reload config (= stop+start) | `ssh jr551@192.168.69.1 '/container/stop [find name=angie]; :delay 3s; /container/start [find name=angie]'` |
| Tail angie logs              | `ssh jr551@192.168.69.1 '/log/print follow where topics~"container"'` (only with `logging=yes` on the container — already set) |
| Edit hello-world page        | Edit `~/angie-deploy/html/index.html`, scp to SSD, restart container.    |
| Edit angie config            | Edit `~/angie-deploy/conf/angie.conf`, scp to SSD, restart container.    |
| Pull a new image version     | `ssh jr551@192.168.69.1 '/container/print detail where name=angie'` to see current digest, then `/container/remove [find name=angie]` and re-add — RouterOS doesn't have an in-place pull. |

## Rolling back to the old `.16.100` webserver

The old NAT rules are present but disabled (`X` flag, comments start with
`Webserver HTTPS …`). To roll back:

1. Disable or remove the four `Angie HTTP/HTTPS WAN/hairpin` rules.
2. `/ip/firewall/nat/enable [find comment~"Webserver HTTPS"]`.

Optional cleanup once you're confident: stop+remove the angie container, drop the
veth, drop the bridge port, drop the three mount entries.
