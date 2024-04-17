{ depot, lib, ... }:

(
  depot.nix.dependency-analyzer.knownDependencyGraph
    "depot"
    depot.ci.targets
).overrideAttrs (old: {
  # Causes an infinite recursion via ci.targets otherwise
  meta = lib.recursiveUpdate (old.meta or { }) {
    ci.skip = true;
  };
})
