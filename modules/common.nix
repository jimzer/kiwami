# Settings every Kiwami host gets, regardless of hardware.
{ lib, pkgs, ... }:

{
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
  };
  nixpkgs.config.allowUnfree = true;

  time.timeZone = lib.mkDefault "Europe/Zurich";
  i18n.defaultLocale = lib.mkDefault "en_US.UTF-8";

  users.users.nixos = {
    isNormalUser = true;
    extraGroups = [ "wheel" "video" "audio" ];
  };
  security.sudo.wheelNeedsPassword = false;

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = lib.mkDefault true;
  };

  environment.systemPackages = with pkgs; [ git vim curl htop rsync jq ];
}
