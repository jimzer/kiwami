# Settings every Kiwami host gets, regardless of hardware.
{ config, lib, pkgs, inputs, ... }:

{
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
  };

  time.timeZone = lib.mkDefault "Europe/Zurich";
  i18n.defaultLocale = lib.mkDefault "en_US.UTF-8";

  users.users.${config.kiwami.user} = {
    isNormalUser = true;
    extraGroups = [ "wheel" "video" "audio" "networkmanager" ];
  };
  security.sudo.wheelNeedsPassword = false;

  # NetworkManager, not scripted DHCP. `kiwami net` drives nmcli, so without
  # this the command ships on every machine and works on none of them - and a
  # laptop with no way to join a wireless network is not a laptop. The VM
  # never noticed, having only ever had a wired connection that came up by
  # itself.
  networking.networkmanager.enable = lib.mkDefault true;
  # NetworkManager owns the interfaces; leaving the scripted DHCP client on as
  # well means two things bringing up the same link.
  networking.useDHCP = lib.mkDefault false;

  # The daemon, running but joined to nothing. `tailscale up` - which is what
  # `kiwami remote` calls - is still an explicit act, so this grants no access
  # by itself; it only means the machine can be reached for help without
  # first having to install something on a machine that has no network.
  services.tailscale.enable = lib.mkDefault true;

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = lib.mkDefault true;
  };

  environment.systemPackages = [
    # The distro's own CLI, built from cli/ by this flake.
    inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.kiwami
  ] ++ (with pkgs; [ git vim curl htop rsync jq ]);
}
