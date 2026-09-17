# Host secrets

Copy `secrets.nix.example` to `secrets.nix`, replace the SSH recipient, and use
agenix to create encrypted secrets locally. This directory is ignored except
for documentation and example files.

Use separate password and TOTP files for the VPN and HPC SSH login. The HPC
files are `rwth-hpc-password.age` and `rwth-hpc-totp-secret.age`; neither
credential is assumed to be shared with the VPN.
