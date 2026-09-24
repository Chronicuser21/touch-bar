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
#   services.omarchyTouchbar = {
#     enable = true;
#     user = "b";
#     tree = inputs.touchbar;   # flake input -> PyGObject settings app
#   };
#
# On NixOS the system python ("/usr/bin/env python3" from install.sh's shebangs)
# has no PyGObject, so the settings window also ships as a wrapper command
# "omarchy-touchbar-settings" in the system profile that runs
# src/omarchy-touchbar-settings under a python3 built with Python-gobject and
# the GTK4/libadwaita typelibs (see the NixOS froth below). install.sh skips
# the ~/.local/bin copy on NixOS so the wrapper stays authoritative.
#
# tiny-dfr itself (the service and its seat/device udev rules) is expected to
# come from the apple-silicon fork's hardware.apple.touchBar.enable, the same
# module whose config.toml this file takes over for live rendering.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.omarchyTouchbar;

  # Python-gobject build of the system interpreter (kept out of the profile:
  # replacing bin/python3 would collide with the python3 already merged there).
  pyGtkEnv = pkgs.python3.withPackages (pythonPkgs: [ pythonPkgs.pygobject3 ]);

  # gi resolves Gtk/Adw only from GI_TYPELIB_PATH (setting it hides the python
  # env's own typelibs), so expose every typelib directory Gtk 4 + libadwaita
  # depend on. Verified on this nixpkgs by importing Gtk/Adw under the env.
  giTypelibPath = lib.makeSearchPathOutput "out" "lib/girepository-1.0" (with pkgs; [
    gtk4
    libadwaita
    graphene
    gdk-pixbuf
    pango
    harfbuzz
    gobject-introspection
  ]);
in
{
  options.services.omarchyTouchbar = {
    enable = lib.mkEnableOption "system wiring for the Omarchy Touch Bar daemon (writable /etc/tiny-dfr, backlight udev rule, post-resume panel reset, PyGObject settings app)";
    user = lib.mkOption {
      type = lib.types.str;
      example = "b";
      description = "Unix account that runs the omarchy-touchbar user service and owns /etc/tiny-dfr.";
    };
    tree = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExample "inputs.touchbar";
      description = "Checkout of the touch-bar flake input hosting src/omarchy-touchbar-settings, e.g. pass the flake input itself (inputs.touchbar). When set, the module installs an omarchy-touchbar-settings wrapper in the system profile (PyGObject python + GTK4/libadwaita typelibs); leave null to skip the wrapper.";
    };
  };

  config = lib.mkIf cfg.enable {
    # tiny-dfr watches /etc/tiny-dfr/config.toml. Drop the declarative store
    # symlink (hardware.apple.touchBar.settings) so the daemon can write a
    # live config in place; tmpfiles below keeps a real file there.
    environment.etc."tiny-dfr/config.toml".enable = lib.mkForce false;

    # The settings window needs python-gobject with GTK4/libadwaita, which the
    # system python lacks. Ship it as a system command so `omarchy-touchbar
    # settings` works without replacing bin/python3 (which would collide).
    environment.systemPackages = lib.mkIf (cfg.tree != null) [
      (pkgs.writeShellScriptBin "omarchy-touchbar-settings" ''
        export GI_TYPELIB_PATH="${giTypelibPath}"
        exec "${pyGtkEnv}/bin/python3" "${cfg.tree}/src/omarchy-touchbar-settings" "$@"
      '')
    ];

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