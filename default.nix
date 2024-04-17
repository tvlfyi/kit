# Externally importable TVL depot stack. This is intended to be called
# with a supplied package set, otherwise the package set currently in
# use by the TVL depot will be used.
#
# For now, readTree is not used inside of this configuration to keep
# it simple. Adding it may be useful if we set up test scaffolding
# around the exported workspace.

{ pkgs ? (import ./nixpkgs {
    depotOverlays = false;
    depot.third_party.sources = import ./sources { };
    externalArgs = args;
  })
, ...
}@args:

pkgs.lib.fix (self: {
  besadii = import ./besadii {
    depot.nix.buildGo = self.buildGo;
  };

  buildGo = import ./buildGo { inherit pkgs; };

  buildkite = import ./buildkite {
    inherit pkgs;
    depot.nix = {
      inherit (self) readTree dependency-analyzer;
    };
  };

  checks = import ./checks { inherit pkgs; };
  dependency-analyzer = import ./dependency-analyzer {
    inherit pkgs;
    inherit (pkgs) lib;
    depot.nix.stateMonad = self.stateMonad;
  };
  lazy-deps = import ./lazy-deps {
    inherit pkgs;
    lib = pkgs.lib;
  };
  magrathea = import ./magrathea { inherit pkgs; };
  readTree = import ./readTree { };
  stateMonad = import ./stateMonad { };
})
