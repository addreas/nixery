# Copyright The TVL Contributors
# SPDX-License-Identifier: Apache-2.0

{ buildGoModule, makeWrapper, xz }:

buildGoModule {
  name = "nixery-popcount";
  pname = "popcount";

  src = ./.;

  vendorHash = null;

  # https://nixos.org/manual/nixpkgs/stable/#buildGoPackage-migration
  postPatch = ''
    go mod init github.com/google/nixery/popcount
  '';

  nativeBuildInputs = [ makeWrapper ];
  postInstall = ''
    wrapProgram $out/bin/popcount \
      --prefix PATH : ${xz}/bin
  '';

  doCheck = true;
}
