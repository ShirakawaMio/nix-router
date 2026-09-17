# Host secrets

Copy `secrets.nix.example` to `secrets.nix`, replace the SSH recipient, and use
agenix to create encrypted secrets locally. This directory is ignored except
for documentation and example files.

Use separate `rwth-password.age` and `rwth-hpc-password.age` files for the VPN
and HPC SSH passwords. They are not necessarily the same credential. The
`rwth-totp-secret.age` seed can be shared by both clients.
