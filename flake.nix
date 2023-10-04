{
  description = "A very basic flake";

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

          subPackages = [ "cmd/server" ];

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
            wrapProgram $out/bin/server \
              --set WEB_DIR "${./web}" \
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
            config.Cmd = [ "server" ];
            config.User = "1000:1000";
            config.Env = [
              "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
              # "NIX_STORE_DIR=/nixery/nix/store"
              # "NIX_LOG_DIR=/nixery/nix/var/log"
              # "NIX_STATE_DIR=/nixery/nix/var"
            ];

            extraCommands = ''
              mkdir -p ./tmp ./nix/{store,var/nix}
              chmod -R a+w ./tmp ./nix/{store,var/nix}

              mkdir -p ./etc/nix
              echo 'sandbox = false' >> ./etc/nix/nix.conf
              echo 'experimental-features = nix-command flakes' >> ./etc/nix/nix.conf
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
