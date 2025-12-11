{
  inputs.nixpkgs.url = "nixpkgs/25.05";
  inputs.systems.url = "github:nix-systems/default";

  outputs = { self, systems, nixpkgs }:
    let
      eachSystem = nixpkgs.lib.genAttrs (import systems);
      nixery-default = system: import ./default.nix { pkgs = nixpkgs.legacyPackages.${system}; };
    in rec {
      packages = eachSystem nixery-default;
      images.x86_64-linux.nixery = packages.x86_64-linux.nixery-image;
    };
}
