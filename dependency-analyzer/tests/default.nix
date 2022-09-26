{ depot, lib, ... }:

let
  inherit (depot.nix.runTestsuite)
    runTestsuite
    assertEq
    it
    ;

  inherit (depot.nix.dependency-analyzer)
    plainDrvDepMap
    drvsToPaths
    ;

  knownDrvs = drvsToPaths (
    builtins.filter lib.isDerivation (builtins.attrValues depot.third_party.lisp)
  );
  exampleMap = plainDrvDepMap knownDrvs;

  # These will be needed to index into the attribute set which can't have context
  # in the attribute names.
  knownDrvsNoContext = builtins.map builtins.unsafeDiscardStringContext knownDrvs;
in

runTestsuite "dependency-analyzer" [
  (it "checks plainDrvDepMap properties" [
    (assertEq "all known drvs are marked known"
      (builtins.all (drv: exampleMap.${drv}.known) knownDrvsNoContext)
      true)
    (assertEq "no unknown drv is marked known"
      (builtins.all (entry: !entry.known) (
        builtins.attrValues (builtins.removeAttrs exampleMap knownDrvsNoContext)
      ))
      true)
  ])
]
