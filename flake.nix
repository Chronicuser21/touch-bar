{
  description = "Omarchy Touch Bar - a context-aware Touch Bar for Intel T2 MacBooks";

  # No inputs: the project is plain scripts plus one self-contained NixOS
  # module. The flake exists so NixOS flakes can consume it as an input
  # (flake inputs must be flakes), e.g. in configuration.nix:
  #
  #   touchbar = { url = "path:/path/to/touch-bar"; };   # or git+file:
  #   imports = [ (import "${inputs.touchbar}/nixos/touchbar.nix") ];

  outputs = { self }: {
    nixosModules.touchbar = import ./nixos/touchbar.nix;
  };
}