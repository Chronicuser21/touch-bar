# NixOS module: declarative system wiring for the Omarchy Touch Bar daemon.
#
# On NixOS /etc is generated read-only, so install.sh cannot imperatively
# write the backlight udev rule, the post-resume panel reset, or a writable
# /etc/tiny-dfr. This module supplies all three so they survive every
# nixos-rebuild:
#   * tmpfiles keeps /etc/tiny-dfr and /etc/tiny-dfr/gen owned by the user who
#     runs the omarchy-touchbar user service, and replaces the declarative
#     read-only store symlink for config.toml (created by
#     hardware.apple.touchBar.settings) with a regular user-owned file that the
#     daemon rewrites in place and tiny-dfr watches;
#   * udev lets the desktop session hold the Touch Bar backlight on, matching
#     integration/99-touchbar-backlight.rules;
#   * the panel-reset unit rebinds the T2 display after resume, matching
#     integration/touchbar-panel-reset.
#
# Import it from configuration.nix and enable it, e.g.:
#   imports = [ /path/to/touch-bar/nixos/touchbar.nix ];
#   services.omarchyTouchbar = { enable = true; user = "b"; };
#
# tiny-dfr itself (the service and its seat/device udev rules) is expected to
# come from the apple-silicon fork's hardware.apple.touchBar.enable, the same
# module whose config.toml this file takes over for live rendering.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.omarchyTouchbar;
in
{
  options.services.omarchyTouchbar = {
    enable = lib.mkEnableOption "system wiring for the Omarchy Touch Bar daemon (writable /etc/tiny-dfr, backlight udev rule, post-resume panel reset)";
    user = lib.mkOption {
      type = lib.types.str;
      example = "b";
      description = "Unix account that runs the omarchy-touchbar user service and owns /etc/tiny-dfr.";
    };
  };

  config = lib.mkIf cfg.enable {
    # tiny-dfr watches /etc/tiny-dfr/config.toml. Drop the declarative store
    # symlink (hardware.apple.touchBar.settings) so the daemon can write a
    # live config in place; tmpfiles below keeps a real file there.
    environment.etc."tiny-dfr/config.toml".enable = lib.mkForce false;

    systemd.tmpfiles.rules = [
      "d /etc/tiny-dfr 0755 ${cfg.user} - - -"
      "d /etc/tiny-dfr/gen 0755 ${cfg.user} - - -"
      "r /etc/tiny-dfr/config.toml"
      "f /etc/tiny-dfr/config.toml 0644 ${cfg.user} - - -"
      "z /etc/tiny-dfr 0755 ${cfg.user} - - -"
      "Z /etc/tiny-dfr/gen 0755 ${cfg.user} - - -"
      "z /etc/tiny-dfr/config.toml 0644 ${cfg.user} - - -"
    ];

    # Let the session hold the Touch Bar backlight on (tiny-dfr blacks the
    # panel out after 60s of no input). Same rule install.sh writes on
    # non-NixOS systems, with @@BIN@@ resolved to a store path.
    services.udev.extraRules = lib.mkAfter ''
      ${lib.replaceStrings [ "@@BIN@@" ] [ "${pkgs.coreutils}/bin" ] (builtins.readFile ../integration/99-touchbar-backlight.rules)}
    '';

    # Rebind the T2 display after suspend so the panel never freezes on its
    # last frame (see integration/touchbar-panel-reset).
    systemd.services.touchbar-panel-reset = {
      description = "Rebind the Touch Bar display after resume";
      after = [
        "suspend.target"
        "hibernate.target"
        "hybrid-sleep.target"
        "suspend-then-hibernate.target"
      ];
      wantedBy = [
        "suspend.target"
        "hibernate.target"
        "hybrid-sleep.target"
        "suspend-then-hibernate.target"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = [
          (pkgs.writeShellScript "touchbar-panel-reset" (builtins.readFile ../integration/touchbar-panel-reset))
        ];
      };
    };
  };
}