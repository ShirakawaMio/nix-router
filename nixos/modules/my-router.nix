{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.my-router;

  inherit (lib)
    concatMapStringsSep
    concatStringsSep
    escapeShellArg
    mkEnableOption
    mkIf
    mkOption
    optional
    optionalAttrs
    optionalString
    optionals
    types
    ;

  package = cfg.package;

  quote = value: escapeShellArg (toString value);
  assign = name: value: "${name}=${quote value}";
  assignRaw = name: value: "${name}=${value}";
  csv = values: concatStringsSep "," values;
  nftSet = values: "{ ${concatStringsSep ", " values} }";
  toml = builtins.toJSON;
  tomlList = values: "[ ${concatStringsSep ", " (map toml values)} ]";

  tokenFromFile = ''"$(cat ${quote cfg.publish.tokenFile})"'';
  publishTokenExpr = if cfg.publish.token == null then tokenFromFile else quote cfg.publish.token;
  publishBaseUrlExpr =
    if cfg.publish.baseUrl != null then
      quote cfg.publish.baseUrl
    else if cfg.publish.token == null then
      "${quote cfg.publish.urlPrefix}/$(cat ${quote cfg.publish.tokenFile})"
    else
      quote "${cfg.publish.urlPrefix}/${cfg.publish.token}";

  publishBaseUrlForToml =
    if cfg.publish.baseUrl != null then
      cfg.publish.baseUrl
    else if cfg.publish.token == null then
      "${cfg.publish.urlPrefix}/generated-token"
    else
      "${cfg.publish.urlPrefix}/${cfg.publish.token}";

  subscriptionStateDir = "${cfg.stateDir}/sub-store";
  autoPeerPrivateKeyFile = "${cfg.stateDir}/secrets/wg-access-auto-peer.key";
  autoPeerPublicKeyFile = "${autoPeerPrivateKeyFile}.pub";
  manualAccessNodeEnabled = cfg.access.clientPrivateKeyFile != null;
  accessNodeEnabled = cfg.access.autoPeer.enable || manualAccessNodeEnabled;
  accessClientPrivateKeyFile =
    if cfg.access.autoPeer.enable then autoPeerPrivateKeyFile else cfg.access.clientPrivateKeyFile;
  subscriptionConfig = builtins.toJSON {
    backend_url = "http://${cfg.subscriptions.backendHost}:${toString cfg.subscriptions.backendPort}";
    collection_name = cfg.subscriptions.collectionName;
    sources_file = cfg.subscriptions.sourcesFile;
    node_interval = cfg.subscriptions.nodeInterval;
    allow_insecure_publication = cfg.subscriptions.allowInsecurePublication;
    access_node = {
      enabled = accessNodeEnabled;
      name = cfg.access.nodeName;
      server = cfg.access.publicEndpoint;
      port = cfg.access.listenPort;
      ip = cfg.access.clientAddress;
      client_private_key_file = accessClientPrivateKeyFile;
      server_private_key_file = cfg.access.privateKeyFile;
    };
  };
  publicationUrl = if cfg.publish.baseUrl != null then cfg.publish.baseUrl else cfg.publish.urlPrefix;

  secretService = optional (cfg.publish.token == null) "my-router-secrets.service";

  envFile = ''
    ${assign "MY_ROUTER_HOSTNAME" cfg.hostname}
    ${assign "MY_ROUTER_CONFIG_DIR" cfg.configDir}
    ${assign "MY_ROUTER_STATE_DIR" cfg.stateDir}
    ${assign "MY_ROUTER_WWW_DIR" "${cfg.stateDir}/www"}
    ${assign "WIREGUARD_DIR" "/etc/wireguard"}

    ${assign "EXT_IF" cfg.externalInterface}
    ${assign "SSH_PORT" cfg.sshPort}
    ${assign "PUBLISH_BIND" cfg.publish.bind}
    ${assign "PUBLISH_PORT" cfg.publish.port}
    ${assignRaw "PUBLISH_TOKEN" publishTokenExpr}
    ${assignRaw "PUBLISH_BASE_URL" publishBaseUrlExpr}

    ${assign "WG_ACCESS_IF" cfg.access.interface}
    ${assign "WG_ACCESS_ADDRESS" cfg.access.address}
    ${assign "WG_ACCESS_CIDR" cfg.access.cidr}
    ${assign "WG_ACCESS_PORT" cfg.access.listenPort}
    ${assign "WG_ACCESS_PRIVATE_KEY_FILE" cfg.access.privateKeyFile}
    ${assign "WG_ACCESS_PEERS_FILE" "${cfg.configDir}/wg-access-peers.conf"}

    ${assign "WG_OFFICE_ENABLED" (if cfg.office.enable then "1" else "0")}
    ${assign "WG_OFFICE_IF" cfg.office.interface}
    ${assign "WG_OFFICE_ADDRESS" cfg.office.address}
    ${assign "WG_OFFICE_PRIVATE_KEY_FILE" cfg.office.privateKeyFile}
    ${assign "WG_OFFICE_PEER_PUBLIC_KEY" cfg.office.peerPublicKey}
    ${assign "WG_OFFICE_ENDPOINT" cfg.office.endpoint}
    ${assign "WG_OFFICE_ALLOWED_IPS" (csv cfg.office.allowedIPs)}
    ${assign "WG_OFFICE_PERSISTENT_KEEPALIVE" cfg.office.persistentKeepalive}

    ${assign "RWTH_ENABLED" (if cfg.rwth.enable then "1" else "0")}
    ${assign "RWTH_NETNS" cfg.rwth.namespace}
    ${assign "RWTH_HOST_IF" cfg.rwth.hostInterface}
    ${assign "RWTH_NS_IF" cfg.rwth.namespaceInterface}
    ${assign "RWTH_HOST_ADDRESS" cfg.rwth.hostAddress}
    ${assign "RWTH_NS_ADDRESS" cfg.rwth.namespaceAddress}
    ${assign "RWTH_HOST_IP" cfg.rwth.hostIp}
    ${assign "RWTH_NS_IP" cfg.rwth.namespaceIp}
    ${assign "RWTH_NETNS_CIDR" cfg.rwth.netnsCidr}
    ${assign "RWTH_GATEWAY" cfg.rwth.gateway}
    ${assign "RWTH_AUTHGROUP" cfg.rwth.authGroup}
    ${assign "RWTH_USER" cfg.rwth.user}
    ${optionalString (cfg.rwth.passwordFile != null) (
      assign "RWTH_PASSWORD_FILE" cfg.rwth.passwordFile
    )}
    ${optionalString (cfg.rwth.totpSecretFile != null) (
      assign "RWTH_TOTP_SECRET_FILE" cfg.rwth.totpSecretFile
    )}
    ${assign "RWTH_OPENCONNECT_PID_FILE" cfg.rwth.pidFile}
    ${assign "RWTH_DNS" cfg.rwth.dns}
    ${assign "RWTH_CIDRS" (csv cfg.rwth.cidrs)}

    ${assign "MY_ROUTER_RULES_CONFIG" "${cfg.configDir}/rules/sources.toml"}
    ${assign "MY_ROUTER_SUBSCRIPTIONS_CONFIG" "${cfg.configDir}/subscriptions/config.json"}
  '';

  rulesToml = ''
    [publish]
    output_root = ${toml "${cfg.stateDir}/www"}
    token = "generated-token"
    public_base_url = ${toml publishBaseUrlForToml}

    [ads]
    prebuilt_base_url = ${
      toml (if cfg.rules.prebuiltAdsBaseUrl == null then "" else cfg.rules.prebuiltAdsBaseUrl)
    }
    urls = ${tomlList (if cfg.rules.prebuiltAdsBaseUrl == null then cfg.rules.adsUrls else [ ])}
    local_files = ${tomlList cfg.rules.adsLocalFiles}

    [office]
    cidrs = ${tomlList cfg.office.allowedIPs}

    [rwth]
    cidrs = ${tomlList cfg.rwth.cidrs}
    domains = ${tomlList cfg.rwth.domains}
  '';

  peerOptions = { ... }: {
    options = {
      publicKey = mkOption {
        type = types.str;
        description = "WireGuard peer public key.";
      };
      allowedIPs = mkOption {
        type = types.listOf types.str;
        description = "Allowed IPs for this WireGuard peer.";
      };
      endpoint = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Optional peer endpoint.";
      };
      persistentKeepalive = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "Optional WireGuard persistent keepalive interval.";
      };
      presharedKeyFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Optional preshared key file.";
      };
    };
  };

  accessForwardRules = ''
    iifname "${cfg.access.interface}" oifname "${cfg.externalInterface}" accept
  ''
  + optionalString (cfg.office.enable && cfg.office.allowedIPs != [ ]) ''
    iifname "${cfg.access.interface}" oifname "${cfg.office.interface}" ip daddr ${nftSet cfg.office.allowedIPs} accept
  ''
  + optionalString (cfg.rwth.enable && cfg.rwth.cidrs != [ ]) ''
    iifname "${cfg.access.interface}" oifname "${cfg.rwth.hostInterface}" ip daddr ${nftSet cfg.rwth.cidrs} accept
    iifname "${cfg.rwth.hostInterface}" oifname "${cfg.externalInterface}" ip saddr ${cfg.rwth.netnsCidr} accept
  '';

  natRules = ''
    oifname "${cfg.externalInterface}" ip saddr ${cfg.access.cidr} masquerade
  ''
  + optionalString cfg.rwth.enable ''
    oifname "${cfg.externalInterface}" ip saddr ${cfg.rwth.netnsCidr} masquerade
    oifname "${cfg.rwth.hostInterface}" ip saddr ${cfg.access.cidr} masquerade
  ''
  + optionalString cfg.office.enable ''
    oifname "${cfg.office.interface}" ip saddr ${cfg.access.cidr} masquerade
  '';
in
{
  options.services.my-router = {
    enable = mkEnableOption "my-router VPN protocol node";

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ../../modules/package.nix { };
      defaultText = "my-router package from this flake";
      description = "Package providing the my-router helper commands.";
    };

    hostname = mkOption {
      type = types.str;
      default = "miople";
      description = "Logical my-router hostname.";
    };

    configDir = mkOption {
      type = types.str;
      default = "/etc/my-router";
      description = "Configuration directory used by helper commands.";
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/my-router";
      description = "State directory for generated rule-provider files and runtime secrets.";
    };

    externalInterface = mkOption {
      type = types.str;
      default = "eth0";
      description = "Public network interface used for outbound NAT.";
    };

    sshPort = mkOption {
      type = types.port;
      default = 22;
      description = "SSH port to keep open in the host firewall.";
    };

    publish = {
      bind = mkOption {
        type = types.str;
        default = ":8080";
        description = "Caddy site address used for publishing generated rule files.";
      };

      port = mkOption {
        type = types.port;
        default = 8080;
        description = "TCP port to open for the publisher.";
      };

      urlPrefix = mkOption {
        type = types.str;
        default = "http://127.0.0.1:8080";
        description = "Public base URL prefix without the publish token path segment.";
      };

      baseUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Exact public base URL. Defaults to urlPrefix plus the publish token.";
      };

      token = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Publish token. Leave null to generate and keep it outside the Nix store.";
      };

      tokenFile = mkOption {
        type = types.str;
        default = "/var/lib/my-router/secrets/publish-token";
        description = "Runtime file containing the generated publish token.";
      };
    };

    access = {
      interface = mkOption {
        type = types.str;
        default = "wg-access";
        description = "WireGuard access interface name.";
      };

      address = mkOption {
        type = types.str;
        default = "10.77.0.1/24";
        description = "WireGuard access interface address.";
      };

      cidr = mkOption {
        type = types.str;
        default = "10.77.0.0/24";
        description = "WireGuard access network CIDR.";
      };

      listenPort = mkOption {
        type = types.port;
        default = 51820;
        description = "WireGuard access UDP listen port.";
      };

      privateKeyFile = mkOption {
        type = types.str;
        default = "/var/lib/my-router/secrets/wg-access.key";
        description = "Runtime WireGuard access private key file.";
      };

      peers = mkOption {
        type = types.listOf (types.submodule peerOptions);
        default = [ ];
        description = "Declarative WireGuard client peers.";
      };

      publicEndpoint = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Public hostname or IP used by the generated client node.";
      };

      clientAddress = mkOption {
        type = types.str;
        default = "10.77.0.2/32";
        description = "WireGuard address assigned to the generated client node.";
      };

      clientPublicKey = mkOption {
        type = types.str;
        default = "";
        description = "Public key of the generated client node.";
      };

      clientPrivateKeyFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Agenix-managed private key used in generated client subscriptions.";
      };

      nodeName = mkOption {
        type = types.str;
        default = "my-router";
        description = "Name of the generated WireGuard client node.";
      };

      autoPeer.enable = mkEnableOption "automatic persistent WireGuard client peer provisioning";
    };

    office = {
      enable = mkEnableOption "office WireGuard client tunnel";

      interface = mkOption {
        type = types.str;
        default = "wg-office";
        description = "Office WireGuard interface name.";
      };

      address = mkOption {
        type = types.str;
        default = "10.88.0.2/32";
        description = "Office WireGuard interface address.";
      };

      privateKeyFile = mkOption {
        type = types.str;
        default = "/var/lib/my-router/secrets/wg-office.key";
        description = "Runtime office WireGuard private key file.";
      };

      peerPublicKey = mkOption {
        type = types.str;
        default = "";
        description = "Office WireGuard peer public key.";
      };

      endpoint = mkOption {
        type = types.str;
        default = "";
        description = "Office WireGuard peer endpoint.";
      };

      allowedIPs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Office/internal CIDR prefixes routed through the office tunnel.";
      };

      persistentKeepalive = mkOption {
        type = types.int;
        default = 25;
        description = "Office WireGuard persistent keepalive interval.";
      };
    };

    rwth = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to prepare the RWTH OpenConnect network namespace.";
      };

      namespace = mkOption {
        type = types.str;
        default = "rwth";
        description = "RWTH network namespace name.";
      };

      hostInterface = mkOption {
        type = types.str;
        default = "vrwth-host";
        description = "Host-side veth interface for the RWTH namespace.";
      };

      namespaceInterface = mkOption {
        type = types.str;
        default = "vrwth-ns";
        description = "Namespace-side veth interface for RWTH.";
      };

      hostAddress = mkOption {
        type = types.str;
        default = "10.78.0.1/30";
        description = "Host-side RWTH veth address.";
      };

      namespaceAddress = mkOption {
        type = types.str;
        default = "10.78.0.2/30";
        description = "Namespace-side RWTH veth address.";
      };

      hostIp = mkOption {
        type = types.str;
        default = "10.78.0.1";
        description = "Host-side RWTH veth IP.";
      };

      namespaceIp = mkOption {
        type = types.str;
        default = "10.78.0.2";
        description = "Namespace-side RWTH veth IP.";
      };

      netnsCidr = mkOption {
        type = types.str;
        default = "10.78.0.0/30";
        description = "RWTH namespace veth CIDR.";
      };

      gateway = mkOption {
        type = types.str;
        default = "vpn.rwth-aachen.de";
        description = "RWTH VPN gateway.";
      };

      authGroup = mkOption {
        type = types.str;
        default = "RWTH-VPN (Split Tunnel)";
        description = "RWTH OpenConnect authgroup.";
      };

      user = mkOption {
        type = types.str;
        default = "";
        description = "RWTH VPN username for interactive OpenConnect.";
      };

      passwordFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Optional file containing the static RWTH VPN password, suitable for agenix secret paths.";
      };

      totpSecretFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Optional file containing the RWTH TOTP seed, suitable for agenix secret paths.";
      };

      pidFile = mkOption {
        type = types.str;
        default = "/run/my-router-rwth-openconnect.pid";
        description = "OpenConnect PID file used when starting in background mode.";
      };

      autoConnect = {
        enable = mkEnableOption "unattended RWTH OpenConnect service";

        restartSec = mkOption {
          type = types.str;
          default = "30s";
          description = "Delay before systemd restarts the RWTH OpenConnect service.";
        };
      };

      dns = mkOption {
        type = types.str;
        default = "1.1.1.1";
        description = "DNS resolver written into the RWTH namespace.";
      };

      cidrs = mkOption {
        type = types.listOf types.str;
        default = [
          "134.130.0.0/16"
          "137.226.0.0/16"
        ];
        description = "RWTH CIDRs forwarded to the RWTH namespace.";
      };

      domains = mkOption {
        type = types.listOf types.str;
        default = [
          "rwth-aachen.de"
          "rwth.de"
        ];
        description = "RWTH domains emitted in client rule providers.";
      };
    };

    rules = {
      prebuiltAdsBaseUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "https://example.github.io/my-router/providers";
        description = ''
          Optional URL containing GitHub Actions-built ads.yaml and
          ads-shadowrocket.list files. When set, remote ad sources are not
          normalized on this host.
        '';
      };

      adsUrls = mkOption {
        type = types.listOf types.str;
        default = [
          "https://raw.githubusercontent.com/217heidai/adblockfilters/main/rules/adblockmihomo.yaml"
        ];
        description = "Remote ad-block rule sources.";
      };

      adsLocalFiles = mkOption {
        type = types.listOf types.str;
        default = [ "/etc/my-router/rules/local-ads.txt" ];
        description = "Local ad-block rule source files.";
      };

      refreshInterval = mkOption {
        type = types.str;
        default = "8h";
        description = "Interval between rule-provider refreshes.";
      };
    };

    subscriptions = {
      enable = mkEnableOption "node and rule subscription aggregation";

      package = mkOption {
        type = types.nullOr types.package;
        default = if pkgs ? sub-store then pkgs.sub-store else null;
        defaultText = "pkgs.sub-store when available";
        description = "Sub-Store package used as the subscription parsing backend.";
      };

      backendHost = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Loopback address for the private Sub-Store backend.";
      };

      backendPort = mkOption {
        type = types.port;
        default = 3000;
        description = "Loopback port for the private Sub-Store backend.";
      };

      collectionName = mkOption {
        type = types.str;
        default = "my-router";
        description = "Internal Sub-Store collection name.";
      };

      sourcesFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Optional agenix-managed JSON file containing local or external node sources.";
      };

      nodeInterval = mkOption {
        type = types.ints.positive;
        default = 3600;
        description = "Client-side node provider refresh interval in seconds.";
      };

      refreshInterval = mkOption {
        type = types.str;
        default = "1h";
        description = "Server-side interval for refreshing external node subscriptions.";
      };

      allowInsecurePublication = mkOption {
        type = types.bool;
        default = false;
        description = "Allow publishing node credentials over a non-HTTPS URL.";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.office.enable -> cfg.office.peerPublicKey != "";
        message = "services.my-router.office.peerPublicKey must be set when office is enabled.";
      }
      {
        assertion = cfg.office.enable -> cfg.office.endpoint != "";
        message = "services.my-router.office.endpoint must be set when office is enabled.";
      }
      {
        assertion = cfg.office.enable -> cfg.office.allowedIPs != [ ];
        message = "services.my-router.office.allowedIPs must be non-empty when office is enabled.";
      }
      {
        assertion = cfg.rwth.autoConnect.enable -> cfg.rwth.passwordFile != null;
        message = "services.my-router.rwth.passwordFile must be set when rwth.autoConnect.enable is true.";
      }
      {
        assertion = cfg.rwth.autoConnect.enable -> cfg.rwth.totpSecretFile != null;
        message = "services.my-router.rwth.totpSecretFile must be set when rwth.autoConnect.enable is true.";
      }
      {
        assertion = cfg.subscriptions.enable -> cfg.subscriptions.package != null;
        message = "services.my-router.subscriptions.package must be set when subscription aggregation is enabled.";
      }
      {
        assertion = accessNodeEnabled -> cfg.access.publicEndpoint != null;
        message = "services.my-router.access.publicEndpoint must be set for the generated access node.";
      }
      {
        assertion = manualAccessNodeEnabled -> cfg.access.clientPublicKey != "";
        message = "services.my-router.access.clientPublicKey must be set when using a manual client private key.";
      }
      {
        assertion = !(cfg.access.autoPeer.enable && manualAccessNodeEnabled);
        message = "services.my-router.access.autoPeer and clientPrivateKeyFile are mutually exclusive.";
      }
      {
        assertion =
          (cfg.subscriptions.sourcesFile == null && !accessNodeEnabled)
          || cfg.subscriptions.allowInsecurePublication
          || lib.hasPrefix "https://" publicationUrl;
        message = "node subscriptions contain credentials; use an HTTPS publish URL or explicitly allow insecure publication.";
      }
    ];

    environment.systemPackages = [
      package
      pkgs.openconnect
      pkgs.wireguard-tools
    ];

    environment.etc."my-router/miople.env".text = envFile;
    environment.etc."my-router/rules/sources.toml".text = rulesToml;
    environment.etc."my-router/rules/local-ads.txt".text = "";
    environment.etc."my-router/subscriptions/config.json".text = subscriptionConfig;
    environment.etc."my-router/wg-access-peers.conf".text = ''
      # WireGuard peers are declared in services.my-router.access.peers.
    '';

    users.groups.my-router-sub-store = mkIf cfg.subscriptions.enable { };
    users.users.my-router-sub-store = mkIf cfg.subscriptions.enable {
      isSystemUser = true;
      group = "my-router-sub-store";
      home = subscriptionStateDir;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0755 root root - -"
      "d ${cfg.stateDir}/www 0755 root root - -"
      "d ${cfg.stateDir}/secrets 0700 root root - -"
    ]
    ++ optionals cfg.subscriptions.enable [
      "d ${subscriptionStateDir} 0700 my-router-sub-store my-router-sub-store - -"
    ];

    systemd.services.my-router-secrets = mkIf (cfg.publish.token == null) {
      description = "Create my-router runtime secrets";
      wantedBy = [ "multi-user.target" ];
      before = [
        "my-router-rules.service"
        "my-router-rwth-netns.service"
      ]
      ++ optionals cfg.subscriptions.enable [ "my-router-subscriptions.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.coreutils ];
      script = ''
        install -d -m 0700 ${quote "${cfg.stateDir}/secrets"}
        if [ ! -s ${quote cfg.publish.tokenFile} ]; then
          umask 077
          token="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40)"
          printf '%s\n' "$token" > ${quote cfg.publish.tokenFile}
        fi
        chmod 0600 ${quote cfg.publish.tokenFile}
      '';
    };

    networking.wg-quick.interfaces = {
      ${cfg.access.interface} = {
        address = [ cfg.access.address ];
        listenPort = cfg.access.listenPort;
        privateKeyFile = cfg.access.privateKeyFile;
        generatePrivateKeyFile = true;
        peers =
          cfg.access.peers
          ++ optional manualAccessNodeEnabled {
            publicKey = cfg.access.clientPublicKey;
            allowedIPs = [ cfg.access.clientAddress ];
          };
      };
    }
    // optionalAttrs cfg.office.enable {
      ${cfg.office.interface} = {
        address = [ cfg.office.address ];
        privateKeyFile = cfg.office.privateKeyFile;
        generatePrivateKeyFile = true;
        peers = [
          {
            publicKey = cfg.office.peerPublicKey;
            endpoint = cfg.office.endpoint;
            allowedIPs = cfg.office.allowedIPs;
            persistentKeepalive = cfg.office.persistentKeepalive;
          }
        ];
      };
    };

    networking.nftables.enable = true;
    networking.firewall = {
      enable = true;
      allowedTCPPorts = [
        cfg.sshPort
        cfg.publish.port
      ]
      ++ optional (lib.hasPrefix "https://" publicationUrl) 80;
      allowedUDPPorts = [ cfg.access.listenPort ];
      filterForward = true;
      extraForwardRules = accessForwardRules;
    };

    systemd.services.my-router-access-auto-peer = mkIf cfg.access.autoPeer.enable {
      description = "Provision the automatic my-router WireGuard access peer";
      after = [ "wg-quick-${cfg.access.interface}.service" ];
      requires = [ "wg-quick-${cfg.access.interface}.service" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.PartOf = [ "wg-quick-${cfg.access.interface}.service" ];
      path = [
        pkgs.coreutils
        pkgs.iproute2
        pkgs.wireguard-tools
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
        ExecStop = pkgs.writeShellScript "my-router-access-auto-peer-remove" ''
          if [ -s ${quote autoPeerPublicKeyFile} ] && ip link show ${quote cfg.access.interface} >/dev/null 2>&1; then
            wg set ${quote cfg.access.interface} peer "$(cat ${quote autoPeerPublicKeyFile})" remove
          fi
        '';
      };
      script = ''
        install -d -m 0700 ${quote "${cfg.stateDir}/secrets"}
        if [ ! -s ${quote autoPeerPrivateKeyFile} ]; then
          wg genkey > ${quote "${autoPeerPrivateKeyFile}.tmp"}
          chmod 0600 ${quote "${autoPeerPrivateKeyFile}.tmp"}
          mv ${quote "${autoPeerPrivateKeyFile}.tmp"} ${quote autoPeerPrivateKeyFile}
        fi
        wg pubkey < ${quote autoPeerPrivateKeyFile} > ${quote "${autoPeerPublicKeyFile}.tmp"}
        chmod 0600 ${quote "${autoPeerPublicKeyFile}.tmp"}
        mv ${quote "${autoPeerPublicKeyFile}.tmp"} ${quote autoPeerPublicKeyFile}
        wg set ${quote cfg.access.interface} \
          peer "$(cat ${quote autoPeerPublicKeyFile})" \
          allowed-ips ${quote cfg.access.clientAddress}
      '';
    };

    networking.nftables.tables."my-router-nat" = mkIf (natRules != "") {
      family = "inet";
      content = ''
        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;
          ${natRules}
        }
      '';
    };

    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
    };

    systemd.services.my-router-rwth-netns = mkIf cfg.rwth.enable {
      description = "my-router RWTH network namespace setup";
      after = [ "network-online.target" ] ++ secretService;
      wants = [ "network-online.target" ];
      requires = secretService;
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${package}/bin/my-router-rwth-netns-up";
        ExecStop = "${package}/bin/my-router-rwth-netns-down";
      };
    };

    systemd.services.my-router-rwth-openconnect =
      mkIf (cfg.rwth.enable && cfg.rwth.autoConnect.enable)
        {
          description = "my-router RWTH OpenConnect VPN";
          after = [
            "network-online.target"
            "my-router-rwth-netns.service"
            "agenix.service"
          ];
          wants = [
            "network-online.target"
            "my-router-rwth-netns.service"
          ];
          requires = [ "my-router-rwth-netns.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "simple";
            Restart = "on-failure";
            RestartSec = cfg.rwth.autoConnect.restartSec;
            ExecStart = "${package}/bin/my-router-rwth-connect --non-inter";
            ExecStop = "${package}/bin/my-router-rwth-disconnect";
          };
        };

    systemd.services.my-router-rules = {
      description = "Synchronize my-router rule provider files";
      after = [ "network-online.target" ] ++ secretService;
      wants = [ "network-online.target" ];
      requires = secretService;
      before = optionals cfg.subscriptions.enable [ "my-router-subscriptions.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${package}/bin/my-router-rules-build";
      };
    };

    systemd.timers.my-router-rules = {
      description = "Synchronize my-router rule provider files";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = cfg.rules.refreshInterval;
        Persistent = true;
      };
    };

    systemd.services.my-router-sub-store = mkIf cfg.subscriptions.enable {
      description = "Private Sub-Store subscription parser for my-router";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        SUB_STORE_BACKEND_API_HOST = cfg.subscriptions.backendHost;
        SUB_STORE_BACKEND_API_PORT = toString cfg.subscriptions.backendPort;
        SUB_STORE_DATA_BASE_PATH = subscriptionStateDir;
        SUB_STORE_CORS_ALLOWED_ORIGINS = "https://sub-store.vercel.app";
      };
      serviceConfig = {
        Type = "simple";
        User = "my-router-sub-store";
        Group = "my-router-sub-store";
        WorkingDirectory = subscriptionStateDir;
        ExecStart = "${cfg.subscriptions.package}/bin/sub-store";
        Restart = "on-failure";
        RestartSec = "5s";
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ subscriptionStateDir ];
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        UMask = "0077";
      };
    };

    systemd.services.my-router-subscriptions = mkIf cfg.subscriptions.enable {
      description = "Aggregate my-router rules and node subscriptions";
      after = [
        "network-online.target"
        "my-router-rules.service"
        "my-router-sub-store.service"
      ]
      ++ optionals accessNodeEnabled [
        "wg-quick-${cfg.access.interface}.service"
      ]
      ++ optionals cfg.access.autoPeer.enable [ "my-router-access-auto-peer.service" ]
      ++ optionals manualAccessNodeEnabled [ "agenix.service" ]
      ++ secretService;
      wants = [
        "network-online.target"
        "my-router-rules.service"
      ];
      requires = [
        "my-router-sub-store.service"
      ]
      ++ optionals accessNodeEnabled [ "wg-quick-${cfg.access.interface}.service" ]
      ++ optionals cfg.access.autoPeer.enable [ "my-router-access-auto-peer.service" ]
      ++ secretService;
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${package}/bin/my-router-subscriptions-build";
      };
    };

    systemd.timers.my-router-subscriptions = mkIf cfg.subscriptions.enable {
      description = "Refresh aggregated my-router node subscriptions";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        OnUnitActiveSec = cfg.subscriptions.refreshInterval;
        Persistent = true;
      };
    };

    services.caddy.enable = true;
    services.caddy.extraConfig = ''
      ${cfg.publish.bind} {
        root * ${cfg.stateDir}/www
        file_server
      }
    '';

    systemd.services.caddy = {
      after = [
        "my-router-rules.service"
      ]
      ++ optionals cfg.subscriptions.enable [ "my-router-subscriptions.service" ];
      wants = [
        "my-router-rules.service"
      ]
      ++ optionals cfg.subscriptions.enable [ "my-router-subscriptions.service" ];
    };
  };
}
