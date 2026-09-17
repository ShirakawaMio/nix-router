# my-router

Nix-managed minimal VPN protocol node for `miople`.

The design keeps routing decisions on the client. `miople` only provides protocol exits and publishes rule files:

```text
client
|-- ads -> REJECT
|-- office CIDR -> WireGuard access tunnel -> miople -> office WireGuard
|-- RWTH CIDR/domain -> WireGuard access tunnel -> miople -> RWTH OpenConnect netns
`-- default -> DIRECT
```

## What This Implements

- `wg-access`: WireGuard server for your own devices.
- `wg-office`: optional WireGuard client to the company network.
- `rwth` network namespace: OpenConnect/AnyConnect to `vpn.rwth-aachen.de` using `RWTH-VPN (Split Tunnel)`.
- `nftables`: minimal forwarding and NAT between the access tunnel, office tunnel, and RWTH namespace.
- Rules publisher: synchronizes GitHub Actions-built ad rules, adds local routing rules, embeds everything into tokenized Mihomo, Stash, and Shadowrocket configs, and serves them with Caddy.
- Subscription aggregator: runs a private Sub-Store backend and renders node feeds plus complete Mihomo and Shadowrocket configs.
- Non-NixOS deployment: a Nix package plus systemd units under `/opt/my-router/current`.

RWTH behavior follows the working parameters from `l-jamora/rwth-vpn-linux`: OpenConnect must be at least `9.20`; the Nix package uses nixpkgs OpenConnect and provides the `vpnc-script` path to the wrapper.

## Safe Dry Run

Before touching `/etc`, systemd, interfaces, nftables, or network namespaces, render the example setup into a temporary directory:

```bash
nix run .#render-dry-run
```

To also test the optional office WireGuard render path:

```bash
nix run .#render-dry-run -- --with-office
```

After editing the real `/etc/my-router/miople.env`, run:

```bash
sudo nix run .#doctor
```

The doctor checks required commands, OpenConnect version, public rule URL settings, WireGuard keys, RWTH settings, CIDR syntax, and rule TOML. It does not start VPNs or apply firewall rules.

## Bootstrap On miople

Install Nix with flakes enabled, then from this checkout:

```bash
sudo nix run .#deploy-miople
```

The first run creates examples under `/etc/my-router`. Edit them before starting the real services:

```bash
sudoedit /etc/my-router/miople.env
sudoedit /etc/my-router/wg-access-peers.conf
sudoedit /etc/my-router/rules/sources.toml
```

Create WireGuard keys outside Git:

```bash
sudo install -d -m 0700 /etc/my-router/secrets
wg genkey | sudo tee /etc/my-router/secrets/wg-access.key >/dev/null
sudo chmod 0600 /etc/my-router/secrets/wg-access.key
```

If office WireGuard is enabled:

```bash
wg genkey | sudo tee /etc/my-router/secrets/wg-office.key >/dev/null
sudo chmod 0600 /etc/my-router/secrets/wg-office.key
```

Then rerun deploy:

```bash
sudo nix run .#deploy-miople
```

Start the managed pieces:

```bash
sudo systemctl start my-router-wg-access.service
sudo systemctl start my-router-rwth-netns.service
sudo systemctl start my-router-nftables.service
sudo systemctl start my-router-rules.service
sudo systemctl start my-router-caddy.service
```

If office WireGuard is enabled:

```bash
sudo systemctl enable --now my-router-wg-office.service
```

## RWTH VPN

Connect interactively because RWTH requires the VPN password and OTP:

```bash
sudo nix run .#rwth-connect
```

Status and disconnect:

```bash
nix run .#rwth-status
sudo nix run .#rwth-disconnect
```

The OpenConnect command is intentionally run inside the `rwth` namespace:

```text
ip netns exec rwth openconnect \
  --protocol=anyconnect \
  --authgroup="RWTH-VPN (Split Tunnel)" \
  --user="$RWTH_USER" \
  vpn.rwth-aachen.de
```

This keeps RWTH-pushed routes and DNS away from the host namespace.
RWTH destination routes use a dedicated policy table selected only for traffic
from the WireGuard client subnet. This prevents an RWTH CIDR from capturing the
public endpoint of a roaming WireGuard client that happens to be on an RWTH
network. The NixOS firewall keeps strict reverse-path checking globally and
allows the expected asymmetric return path only on the RWTH host veth.

To use the NixOS host as an SSH jump host for RWTH systems, declare every local
jump user so its outbound connections use the same policy table:

```nix
services.my-router.rwth.routeUsers = [ "router" ];
```

Then connect with, for example, `ssh -J router@vpn.example.com
cluster-user@login23-g-1.hpc.itc.rwth-aachen.de`.

### Automatic RWTH HPC login

The optional `rwth-hpc-login` module starts the target SSH client on the jump
host so it can answer RWTH's keyboard-interactive password and TOTP prompts
from agenix secrets. Pin the target host key and grant only selected local
users access to the decrypted files:

```nix
services.rwth-hpc-login = {
  enable = true;
  targetUser = "replace-with-rwth-user";
  users = [ "router" ];
  passwordFile = config.age.secrets.rwth-hpc-password.path;
  totpSecretFile = config.age.secrets.rwth-totp-secret.path;
  hostPublicKey = "ssh-ed25519 AAAA...";
};

age.secrets.rwth-hpc-password = {
  file = ./secrets/rwth-hpc-password.age;
  group = "rwth-hpc-login";
  mode = "0440";
};

age.secrets.rwth-totp-secret = {
  file = ./secrets/rwth-totp-secret.age;
  group = "rwth-hpc-login";
  mode = "0440";
};
```

Create the separate encrypted HPC password on the NixOS host:

```bash
cd /etc/nixos/secrets
sudo env EDITOR=vim RULES=/etc/nixos/secrets/secrets.nix \
  agenix -e rwth-hpc-password.age -i /etc/ssh/ssh_host_ed25519_key
sudo nixos-rebuild switch --flake /etc/nixos#good-girl-prototype
```

Run `ssh -t router@vpn.example.com rwth-hpc-login` for an interactive login.
To keep `ssh rwth` as the local command, use a host alias that logs into the
jump host and starts the helper there:

```sshconfig
Host rwth
  HostName vpn.example.com
  User router
  RequestTTY force
  RemoteCommand rwth-hpc-login
```

This alias intentionally replaces `ProxyJump`: with a transparent proxy the
target authentication remains on the local SSH client and cannot be answered
by the jump host. Keep the HPC login password in a separate secret from
`rwth-password.age`: RWTH VPN and HPC SSH may use different passwords.

### NixOS agenix auto-connect

The NixOS host profile uses agenix for unattended RWTH OpenConnect secrets. The
auto-connect systemd unit is declared only after both encrypted files exist:

```text
/etc/nixos/secrets/rwth-password.age
/etc/nixos/secrets/rwth-totp-secret.age
```

On the NixOS host, create them with:

```bash
cd /etc/nixos/secrets
sudo env EDITOR=vim RULES=/etc/nixos/secrets/secrets.nix agenix -e rwth-password.age -i /etc/ssh/ssh_host_ed25519_key
sudo env EDITOR=vim RULES=/etc/nixos/secrets/secrets.nix agenix -e rwth-totp-secret.age -i /etc/ssh/ssh_host_ed25519_key
sudo nixos-rebuild switch --flake /etc/nixos#nixos
```

`rwth-password.age` contains the static RWTH VPN password. `rwth-totp-secret.age`
contains the TOTP seed, for example `base32:...`, not the current six-digit OTP.
OpenConnect then generates OTP codes itself.

Check the persistent connection with:

```bash
systemctl status my-router-rwth-openconnect
journalctl -u my-router-rwth-openconnect -f
my-router-rwth-status
```

## Subscription Aggregation

NixOS runs two separate declarative services:

- `my-router-rules.service` downloads pre-normalized ad rules and generates the small office and RWTH rule sets locally.
- `my-router-sub-store.service` parses local and external node formats on `127.0.0.1` only.
- `my-router-subscriptions.service` combines both into client-facing files.

Node sources are optional. When configured, they live in the agenix secret
`/etc/nixos/secrets/subscription-sources.age` and use this JSON schema:

```json
{
  "subscriptions": [
    {
      "name": "provider-a",
      "url": "https://provider.example/secret-subscription-url",
      "user_agent": "clash.meta"
    },
    {
      "name": "local-wireguard",
      "content": "proxies:\n  - name: my-router\n    type: wireguard\n    server: vpn.example.com\n    port: 51820\n    ip: 10.77.0.2/32\n    private-key: CLIENT_PRIVATE_KEY\n    public-key: SERVER_PUBLIC_KEY\n    udp: true\n"
    }
  ]
}
```

Create or edit it on the NixOS host with:

```bash
cd /etc/nixos/secrets
sudo env EDITOR=vim RULES=/etc/nixos/secrets/secrets.nix \
  agenix -e subscription-sources.age \
  -i /etc/ssh/ssh_host_ed25519_key
sudo nixos-rebuild switch --flake /etc/nixos#nixos
```

Node subscriptions contain credentials. The module refuses to enable a
non-empty `subscription-sources.age` while the publish URL uses plain HTTP.
Configure Caddy-managed HTTPS first. `allowInsecurePublication = true` exists
only as an explicit escape hatch for a trusted private network.

The host profile also provisions one `my-router` WireGuard access node. With
`services.my-router.access.autoPeer.enable = true`, a declarative oneshot
service generates its persistent client key on first boot, derives the public
key, and registers the peer on `wg-access`. No key generation or public-key
copying is required. External sources are merged after this built-in node.

### GitHub Actions rule builds

The `Publish rules` workflow downloads and normalizes the public ad-block source
every 8 hours, then publishes `ads.yaml` and `ads-shadowrocket.list` with GitHub
Pages. In the repository settings, select **GitHub Actions** as the Pages source,
then configure the NixOS host with:

```nix
services.my-router.rules.prebuiltAdsBaseUrl =
  "https://YOUR_GITHUB_USER.github.io/YOUR_REPOSITORY/providers";
```

The server downloads those two already-normalized files instead of processing
the upstream list. Local office and RWTH rules are still generated on the host,
and the subscription builder embeds all rules into the final Mihomo and
Shadowrocket files. Clients therefore do not depend on GitHub Pages after an
import or refresh from the router.

## Published URLs

After both builders complete, Caddy serves:

```text
/$PUBLISH_TOKEN/mihomo.yaml
/$PUBLISH_TOKEN/stash.yaml
/$PUBLISH_TOKEN/shadowrocket.conf
/$PUBLISH_TOKEN/nodes/mihomo.yaml
/$PUBLISH_TOKEN/nodes/shadowrocket.txt
/$PUBLISH_TOKEN/providers/ads.yaml
/$PUBLISH_TOKEN/providers/office-cidr.yaml
/$PUBLISH_TOKEN/providers/rwth.yaml
/$PUBLISH_TOKEN/providers/ads-shadowrocket.list
/$PUBLISH_TOKEN/providers/office-shadowrocket.list
/$PUBLISH_TOKEN/providers/rwth-shadowrocket.list
```

The default ad-block source is `217heidai/adblockfilters`. GitHub Actions builds
it every 8 hours to match the upstream publication schedule, and the server
synchronizes the resulting files on the same interval. External node sources
refresh hourly by default.

Mihomo and Clash Verge need only `mihomo.yaml`; all nodes and rules are embedded
in that file when it is generated. In Shadowrocket, add
`nodes/shadowrocket.txt` as the server subscription, then import
`shadowrocket.conf` as the active config. The node feed is a Base64-encoded URI
subscription understood by Shadowrocket. All ad, office, and RWTH rules are
embedded in `shadowrocket.conf`, so neither client depends on a remote rule-set
after import. The separately published provider files remain for compatibility.

The public NixOS profile keeps deployment-specific values in ignored files.
Create `nixos/hosts/nixos/local.nix` from `local.nix.example`, use the generated
`hardware-configuration.nix` from the target host, and create a local
`secrets/secrets.nix` from its example. The HTTPS hostname may use a CDN, while
the WireGuard hostname must resolve directly when that CDN does not proxy UDP.
Ports 80 and 443 are opened declaratively for certificate issuance and HTTPS.
For non-NixOS deployments, set `PUBLISH_BIND`, `PUBLISH_TOKEN`, and
`PUBLISH_BASE_URL`, for example:

```bash
PUBLISH_BIND=vpn.example.com
PUBLISH_PORT=443
PUBLISH_TOKEN=replace-with-a-long-random-token
PUBLISH_BASE_URL=https://vpn.example.com/replace-with-a-long-random-token
```

## Local Checks

```bash
nix flake check
nix run .#render-dry-run
bash -n scripts/my-router-*
python3 -m py_compile scripts/my-router-rules-build.py scripts/my-router-subscriptions-build.py
python3 scripts/my-router-rules-build.py --check rules/sources.toml.example
```
