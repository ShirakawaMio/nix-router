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
        { pkgs, ... }: {
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
        }
      );

      nixosModules.default = ./nixos/modules/my-router.nix;
    };
}
