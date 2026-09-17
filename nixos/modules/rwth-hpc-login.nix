{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.rwth-hpc-login;

  inherit (lib)
    escapeShellArg
    genAttrs
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  askpass = pkgs.writeShellApplication {
    name = "rwth-hpc-askpass";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      prompt="''${1:-}"
      prompt="''${prompt,,}"

      case "$prompt" in
        *password*)
          password=""
          IFS= read -r password < ${escapeShellArg cfg.passwordFile} || test -n "$password"
          printf '%s\n' "$password"
          ;;
        *two-factor*|*verification\ code*|*one-time*|*otp*)
          seed="$(tr -d '[:space:]' < ${escapeShellArg cfg.totpSecretFile})"
          case "$seed" in
            [Bb][Aa][Ss][Ee]32:*) seed="''${seed#*:}" ;;
          esac

          test -n "$seed"
          printf '%s\n' "$seed" | ${pkgs.oath-toolkit}/bin/oathtool --totp --base32 -
          ;;
        *)
          printf 'rwth-hpc-login: unsupported authentication prompt\n' >&2
          exit 1
          ;;
      esac
    '';
  };

  client = pkgs.writeShellApplication {
    name = cfg.commandName;
    text = ''
      if [[ "''${1:-}" == "--help" || "''${1:-}" == "-h" ]]; then
        cat <<'EOF'
Usage: ${cfg.commandName} [COMMAND [ARG...]]

Open an SSH session to ${cfg.targetUser}@${cfg.targetHost}. The RWTH password
and current TOTP code are supplied from the host's agenix-managed secrets.
EOF
        exit 0
      fi

      export SSH_ASKPASS=${escapeShellArg "${askpass}/bin/rwth-hpc-askpass"}
      export SSH_ASKPASS_REQUIRE=force
      export DISPLAY="''${DISPLAY:-rwth-hpc-login}"

      exec ${pkgs.openssh}/bin/ssh \
        -tt \
        -o BatchMode=no \
        -o ConnectTimeout=${toString cfg.connectTimeout} \
        -o GlobalKnownHostsFile=/etc/ssh/ssh_known_hosts \
        -o KbdInteractiveAuthentication=yes \
        -o PasswordAuthentication=no \
        -o PreferredAuthentications=keyboard-interactive \
        -o PubkeyAuthentication=no \
        -o StrictHostKeyChecking=yes \
        -o UpdateHostKeys=no \
        -o UserKnownHostsFile=/dev/null \
        ${escapeShellArg "${cfg.targetUser}@${cfg.targetHost}"} \
        "$@"
    '';
  };
in
{
  options.services.rwth-hpc-login = {
    enable = mkEnableOption "automatic RWTH HPC SSH two-factor authentication";

    targetHost = mkOption {
      type = types.str;
      default = "login23-g-1.hpc.itc.rwth-aachen.de";
      description = "RWTH HPC SSH hostname reached through the VPN.";
    };

    targetUser = mkOption {
      type = types.str;
      default = "";
      example = "ab123456";
      description = "RWTH HPC username.";
    };

    hostPublicKey = mkOption {
      type = types.str;
      default = "";
      description = "Pinned SSH host public key for the RWTH HPC target.";
    };

    passwordFile = mkOption {
      type = types.str;
      default = "";
      example = "/run/agenix/rwth-password";
      description = "File containing the static RWTH password.";
    };

    totpSecretFile = mkOption {
      type = types.str;
      default = "";
      example = "/run/agenix/rwth-totp-secret";
      description = "File containing the Base32 TOTP seed, optionally prefixed with base32:.";
    };

    users = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "router" ];
      description = "Local users allowed to read the credentials and run automatic login.";
    };

    secretGroup = mkOption {
      type = types.str;
      default = "rwth-hpc-login";
      description = "System group granted read access to the agenix credential files.";
    };

    commandName = mkOption {
      type = types.str;
      default = "rwth-hpc-login";
      description = "Name of the installed login command.";
    };

    connectTimeout = mkOption {
      type = types.ints.positive;
      default = 15;
      description = "SSH connection timeout in seconds.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.targetUser != "";
        message = "services.rwth-hpc-login.targetUser must be set.";
      }
      {
        assertion = cfg.hostPublicKey != "";
        message = "services.rwth-hpc-login.hostPublicKey must be set.";
      }
      {
        assertion = cfg.passwordFile != "";
        message = "services.rwth-hpc-login.passwordFile must be set.";
      }
      {
        assertion = cfg.totpSecretFile != "";
        message = "services.rwth-hpc-login.totpSecretFile must be set.";
      }
      {
        assertion = cfg.users != [ ];
        message = "services.rwth-hpc-login.users must contain at least one local user.";
      }
    ];

    environment.systemPackages = [ client ];

    programs.ssh.knownHosts."rwth-hpc-login-target" = {
      hostNames = [ cfg.targetHost ];
      publicKey = cfg.hostPublicKey;
    };

    users.groups.${cfg.secretGroup} = { };
    users.users = genAttrs cfg.users (_: {
      extraGroups = [ cfg.secretGroup ];
    });
  };
}
