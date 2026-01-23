{ pkgs, ... }:

pkgs.buildGoModule {
  name = "builderball";
  src = pkgs.nix-gitignore.gitignoreSource [ ] ./.;
  vendorHash = "sha256:1prdkm05bdbyinwwgrbwl8pazayg5cp61dlkmygxwbp880zxpqfm";
  meta.description = "Nix cache proxy which forwards clients to the first available cache";
}
