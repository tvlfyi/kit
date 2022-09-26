{ depot, lib, ... }:

depot.nix.dependency-analyzer.knownDependencyGraph "3p-lisp" (
  builtins.filter lib.isDerivation (builtins.attrValues depot.third_party.lisp)
)
