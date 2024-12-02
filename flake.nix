{
  description = "A very basic flake";

  inputs.nixpkgs.url = "nixpkgs/24.05";
  inputs.systems.url = "github:nix-systems/default-linux";

  outputs = { self, systems, nixpkgs }:
    let
      eachSystem = mkSystem: builtins.foldl' (a: b: a // b) { } (builtins.map mkSystem (import systems));
    in
    eachSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        nixery = pkgs.buildGoModule rec {
          name = "nixery";
          src = pkgs.lib.sources.sourceFilesBySuffices ./. [ ".go" "prepare-image.nix" "go.mod" "go.sum" ];
          doCheck = false;

          subPackages = [ "cmd/nixery" ];

          # Needs to be updated after every modification of go.mod/go.sum
          vendorHash = "sha256-RK6uG7UzJo4UJ5uibtq0bXvjalJUWMYUU91FfxOxDF0=";

          ldflags = [
            "-s"
            "-w"
            "-X"
            "main.version=${self.sourceInfo.narHash}"
            "-X"
            "builder.hostSystem=${system}"
          ];

          nativeBuildInputs = [ pkgs.makeWrapper ];
          postInstall = ''
            wrapProgram $out/bin/nixery \
              --set-default NIXERY_WEB_DIR "${./web}" \
              --set-default NIXERY_PREPARE_IMAGE_SCRIPT "${./builder/prepare-image.nix}"
          '';
        };
      in
      {
        formatter.${system} = pkgs.nixpkgs-fmt;

        packages.${system} = {
          default = nixery;
          nixery = nixery;
        };

        # Container image containing Nixery and Nix itself. This image can
        # be run on Kubernetes, published on AppEngine or whatever else is
        # desired.
        images.${system}.nixery =
          pkgs.dockerTools.buildLayeredImage {
            name = "nixery";
            config = {
              Cmd = [ "nixery" ];
              User = "1000:1000";
              Env = [
                "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
              ];
              WorkingDir = "/nixery";
              Volumes = {
                "/nixery" = { };
                "/tmp" = { };
              };
            };

            uid = 1000;
            gid = 1000;
            uname = "nixery";
            gname = "nixery";

            extraCommands = ''
              mkdir -p ./nix/{store,var/nix,var/log}
              chmod -R a+w ./nix/{store,var/nix,var/log}

              mkdir -p ./etc/nix 
              echo 'sandbox = false' >> ./etc/nix/nix.conf
              echo 'experimental-features = nix-command flakes' >> ./etc/nix/nix.conf
              echo 'substituters = https://nix-community.cachix.org https://cache.nixos.org' >> ./etc/nix/nix.conf
              echo 'trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=' >> ./etc/nix/nix.conf
            '';

            maxLayers = 20;
            contents = with pkgs; [
              (dockerTools.fakeNss.override {
                extraPasswdLines = [ "nixery:x:1000:1000:nixery:/nixery:/bin/sh" ];
                extraGroupLines = [ "nixery:x:1000:" ];
              })
              bashInteractive
              cacert
              coreutils
              # git
              # gnutar
              # gzip
              # iana-etc
              nix
              nixery
              # openssh
              # zlib
            ];
          };
      });
}
