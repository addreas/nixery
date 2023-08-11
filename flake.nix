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
      in
      {
        formatter.${system} = pkgs.nixpkgs-fmt;

        packages.${system} = {
          default = self.packages.${system}.nixery;
          nixery = pkgs.buildGoModule rec {
            name = "nixery";
            src = ./.;
            doCheck = true;

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
        };

        # Container image containing Nixery and Nix itself. This image can
        # be run on Kubernetes, published on AppEngine or whatever else is
        # desired.
        images.${system}.nixery =
          let
            # Wrapper script for the wrapper script (meta!) which configures
            # the container environment appropriately.
            #
            # Most importantly, sandboxing is disabled to avoid privilege
            # issues in containers.
            nixery-launch-script = pkgs.writeShellScriptBin "nixery" ''
              set -e
              export PATH=${pkgs.coreutils}/bin:$PATH
              export NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt
              mkdir -p /tmp

              # Create the build user/group required by Nix
              echo 'nixbld:x:30000:nixbld' >> /etc/group
              echo 'nixbld:x:30000:30000:nixbld:/tmp:/bin/bash' >> /etc/passwd
              echo 'root:x:0:0:root:/root:/bin/bash' >> /etc/passwd
              echo 'root:x:0:' >> /etc/group

              # Disable sandboxing to avoid running into privilege issues
              mkdir -p /etc/nix
              echo 'sandbox = false' >> /etc/nix/nix.conf

              # In some cases users building their own image might want to
              # customise something on the inside (e.g. set up an environment
              # for keys or whatever).
              #
              # This can be achieved by setting a '/etc/nixery/pre-launch.sh' script.
              [[ -x /etc/nixery/pre-launch.sh ]] && /etc/nixery/pre-launch.sh

              exec ${self.packages.${system}.nixery}/bin/server
            '';
          in
          pkgs.dockerTools.buildLayeredImage {
            name = "nixery";
            config.Cmd = [ "${nixery-launch-script}/bin/nixery" ];

            maxLayers = 20;
            contents = with pkgs; [
              bashInteractive
              cacert
              coreutils
              git
              gnutar
              gzip
              iana-etc
              nix
              nixery-launch-script
              openssh
              zlib
            ];
          };
      });
}
