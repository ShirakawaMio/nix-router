# Secrets

Do not commit real keys or VPN credentials.

On miople, create these files manually:

```bash
sudo install -d -m 0700 /etc/my-router/secrets
wg genkey | sudo tee /etc/my-router/secrets/wg-access.key >/dev/null
sudo chmod 0600 /etc/my-router/secrets/wg-access.key
```

If miople also acts as the office WireGuard client:

```bash
wg genkey | sudo tee /etc/my-router/secrets/wg-office.key >/dev/null
sudo chmod 0600 /etc/my-router/secrets/wg-office.key
```

On NixOS, RWTH credentials and subscription sources are encrypted with agenix.
The optional `subscription-sources.age` file contains external subscription
URLs or local node definitions; never place those values directly in Nix files.
The built-in client node key is generated automatically and persisted under
`/var/lib/my-router/secrets`; it does not need an agenix input secret.
