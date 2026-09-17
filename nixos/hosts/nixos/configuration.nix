{
  lib,
  pkgs,
  agenix,
  my-router,
  unstablePkgs,
  ...
}:

let
  hardwareModule =
    if builtins.pathExists ./hardware-configuration.nix then
      ./hardware-configuration.nix
    else
      ./hardware-configuration.nix.example;
in
{
  imports = [
    hardwareModule
    my-router.nixosModules.default
    my-router.nixosModules.rwth-hpc-login
  ]
  ++ lib.optional (builtins.pathExists ./local.nix) ./local.nix;

  networking.hostName = lib.mkDefault "my-router";
  networking.useDHCP = lib.mkDefault true;

  time.timeZone = "Etc/UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = lib.mkDefault false;
  };

  users.mutableUsers = lib.mkDefault false;
  security.sudo.wheelNeedsPassword = true;

  environment.systemPackages = [
    agenix.packages.${pkgs.system}.default
    pkgs.git
    pkgs.vim
  ];

  age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  services.my-router = {
    enable = true;
    subscriptions = {
      enable = true;
      package = unstablePkgs.sub-store;
    };
  };

  system.stateVersion = "24.11";
}
