{
  lib,
  stdenvNoCC,
  makeWrapper,
  bash,
  caddy,
  coreutils,
  curl,
  gawk,
  gnugrep,
  gnused,
  iproute2,
  nftables,
  fetchFromGitLab,
  getent,
  openconnect,
  procps,
  python3,
  systemd,
  util-linux,
  wireguard-tools,
  vpnc-scripts,
}:

let
  rwthOpenconnect = openconnect.overrideAttrs (_old: rec {
    version = "9.21";
    src = fetchFromGitLab {
      owner = "openconnect";
      repo = "openconnect";
      rev = "v${version}";
      hash = "sha256-Jtd4cIR6BWSQPmLm8UOvlEcC1g6QlMgFw/aM7cokOCw=";
    };
  });
in
stdenvNoCC.mkDerivation {
  pname = "my-router-tools";
  version = "0.1.0";

  src = ../.;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin" "$out/share/my-router"
    cp -r hosts modules rules secrets subscriptions "$out/share/my-router/"
    for script in scripts/*; do
      if [[ -f "$script" ]]; then
        install -Dm755 "$script" "$out/bin/$(basename "$script")"
      fi
    done

    for program in "$out"/bin/*; do
      case "$program" in
        */my-router-lib.sh|*/my-router-rules-build.py|*/my-router-subscriptions-build.py) continue ;;
      esac
      wrapProgram "$program" \
        --prefix PATH : ${
          lib.makeBinPath [
            bash
            caddy
            coreutils
            curl
            gawk
            getent
            gnugrep
            gnused
            iproute2
            nftables
            rwthOpenconnect
            procps
            python3
            systemd
            util-linux
            wireguard-tools
          ]
        } \
        --set-default MY_ROUTER_SHARE "$out/share/my-router" \
        --set-default MY_ROUTER_VPNC_SCRIPT "${vpnc-scripts}/bin/vpnc-script"
    done

    runHook postInstall
  '';
}
