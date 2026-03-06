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
  examplePlainMap = plainDrvDepMap knownDrvs;
  exampleKnownMap = depot.nix.dependency-analyzer knownDrvs;

  # These will be needed to index into the attribute set which can't have context
  # in the attribute names.
  knownDrvsNoContext = builtins.map builtins.unsafeDiscardStringContext knownDrvs;
in

runTestsuite "dependency-analyzer" [
  (it "produces well-formed plainDrvDepMaps" [
    (assertEq "all known drvs are marked known"
      (builtins.all (drv: examplePlainMap.${drv}.known) knownDrvsNoContext)
      true)
    (assertEq "no unknown drv is marked known"
      (builtins.all (entry: !entry.known) (
        builtins.attrValues (builtins.removeAttrs examplePlainMap knownDrvsNoContext)
      ))
      true)
  ])
  (
    let
      drvPath = d: builtins.unsafeDiscardStringContext d.drvPath;
      inherit (depot.third_party.lisp) easy-routes hunchentoot;
    in
    it "detects dependencies" [
      (assertEq "easy-routes depends on hunchentoot"
        (builtins.elem (drvPath hunchentoot) exampleKnownMap.${drvPath easy-routes}.knownDeps)
        true)
    ]
  )
]
