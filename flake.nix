{
  description = "Nix-managed minimal VPN protocol node for miople";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f {
            inherit system;
            pkgs = import nixpkgs { inherit system; };
          }
        );
    in
    {
      packages = forAllSystems (
        { pkgs, ... }: {
          default = pkgs.callPackage ./modules/package.nix { };
        }
      );

      apps = forAllSystems (
        { system, ... }:
        let
          pkg = self.packages.${system}.default;
          app = name: {
            type = "app";
            program = "${pkg}/bin/${name}";
          };
        in
        {
          default = app "my-router-help";
          doctor = app "my-router-doctor";
          deploy-miople = app "my-router-deploy";
          render = app "my-router-render";
          render-dry-run = app "my-router-render-dry-run";
          rules-build = app "my-router-rules-build";
          subscriptions-build = app "my-router-subscriptions-build";
          rwth-connect = app "my-router-rwth-connect";
          rwth-disconnect = app "my-router-rwth-disconnect";
          rwth-status = app "my-router-rwth-status";
          wg-down = app "my-router-wg-down";
          wg-up = app "my-router-wg-up";
        }
      );

      checks = forAllSystems (
        { pkgs, system, ... }:
        let
          rwthHpcLoginEvaluation = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.rwth-hpc-login
              {
                system.stateVersion = "24.11";
                users.users.test.isNormalUser = true;
                services.rwth-hpc-login = {
                  enable = true;
                  targetUser = "ab123456";
                  hostPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKOr079DWsli+ySeDvGr+S4APZaMc36Fquer++FZh0px";
                  passwordFile = "/run/agenix/rwth-password";
                  totpSecretFile = "/run/agenix/rwth-totp-secret";
                  users = [ "test" ];
                };
              }
            ];
          };
          rwthHpcLoginPackage = nixpkgs.lib.findFirst (
            package: package.name or "" == "rwth-hpc-login"
          ) (throw "rwth-hpc-login package was not installed") rwthHpcLoginEvaluation.config.environment.systemPackages;
        in
        {
          shell-syntax =
            pkgs.runCommand "my-router-shell-syntax"
              {
                nativeBuildInputs = [ pkgs.bash ];
              }
              ''
                for script in ${./scripts}/*.sh ${./scripts}/my-router-*; do
                  case "$script" in
                    *.py) ;;
                    *) bash -n "$script" ;;
                  esac
                done
                sed \
                  -e '/^source /d' \
                  -e '/^main "\$@"$/d' \
                  ${./scripts}/my-router-rwth-netns-up > "$TMPDIR/rwth-netns-up"
                source "$TMPDIR/rwth-netns-up"
                declare -F configure_policy_routes >/dev/null
                touch "$out"
              '';

          python-syntax =
            pkgs.runCommand "my-router-python-syntax"
              {
                nativeBuildInputs = [ pkgs.python3 ];
              }
              ''
                PYTHONPYCACHEPREFIX=$TMPDIR python -m py_compile \
                  ${./scripts}/my-router-rules-build.py \
                  ${./scripts}/my-router-subscriptions-build.py
                MY_ROUTER_RULES_SCRIPT=${./scripts}/my-router-rules-build.py \
                  python -m unittest discover -s ${./tests}
                touch "$out"
              '';

          rwth-hpc-login-module = pkgs.runCommand "rwth-hpc-login-module" { } ''
            ${rwthHpcLoginPackage}/bin/rwth-hpc-login --help | grep -F \
              'Usage: rwth-hpc-login [COMMAND [ARG...]]'
            touch "$out"
          '';
        }
      );

      nixosModules = {
        default = ./nixos/modules/my-router.nix;
        rwth-hpc-login = ./nixos/modules/rwth-hpc-login.nix;
      };
    };
}
