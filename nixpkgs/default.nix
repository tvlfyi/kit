# This file imports the pinned nixpkgs sets and applies relevant
# modifications, such as our overlays.
#
# The actual source pinning happens via niv in //third_party/sources
#
# Note that the attribute exposed by this (third_party.nixpkgs) is
# "special" in that the fixpoint used as readTree's config parameter
# in //default.nix passes this attribute as the `pkgs` argument to all
# readTree derivations.

{ depot ? { }
, externalArgs ? { }
, depotOverlays ? true
, localSystem ? externalArgs.localSystem or builtins.currentSystem
, ...
}:

let
  # Arguments passed to both the stable nixpkgs and the main, unstable one.
  # Includes everything but overlays which are only passed to unstable nixpkgs.
  commonNixpkgsArgs = {
    # allow users to inject their config into builds (e.g. to test CA derivations)
    config =
      (if externalArgs ? nixpkgsConfig then externalArgs.nixpkgsConfig else { })
      // {
        allowUnfree = true;
        allowBroken = true;
        # Forbids our meta.ci attribute
        # https://github.com/NixOS/nixpkgs/pull/191171#issuecomment-1260650771
        checkMeta = false;
      };

    inherit localSystem;
  };

  # import the nixos-unstable package set, or optionally use the
  # source (e.g. a path) specified by the `nixpkgsBisectPath`
  # argument. This is intended for use-cases where the depot is
  # bisected against nixpkgs to find the root cause of an issue in a
  # channel bump.
  nixpkgsSrc = externalArgs.nixpkgsBisectPath or depot.third_party.sources.nixpkgs;

  # Stable package set is imported, but not exposed, to overlay
  # required packages into the unstable set.
  stableNixpkgs = import depot.third_party.sources.nixpkgs-stable commonNixpkgsArgs;

  # Overlay for packages that should come from the stable channel
  # instead (e.g. because something is broken in unstable).
  # Use `stableNixpkgs` from above.
  stableOverlay = _unstableSelf: _unstableSuper: {
    inherit (stableNixpkgs)
      # binaryen does not build on unstable as of 2022-08-22
      binaryen

      # mysql80 is broken as of 2023-04-26, but should work after the next
      # staging-next cycle: https://github.com/NixOS/nixpkgs/issues/226673
      mysql80
      ;
  };

  # Overlay to expose the nixpkgs commits we are using to other Nix code.
  commitsOverlay = _: _: {
    nixpkgsCommits = {
      unstable = depot.third_party.sources.nixpkgs.rev;
      stable = depot.third_party.sources.nixpkgs-stable.rev;
    };
  };
in
import nixpkgsSrc (commonNixpkgsArgs // {
  overlays = [
    commitsOverlay
    stableOverlay
  ] ++ (if depotOverlays then [
    depot.third_party.overlays.haskell
    depot.third_party.overlays.emacs
    depot.third_party.overlays.tvl
    depot.third_party.overlays.ecl-static
    depot.third_party.overlays.dhall
    (import depot.third_party.sources.rust-overlay)
  ] else [ ]);
})
