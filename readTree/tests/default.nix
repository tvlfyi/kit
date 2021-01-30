{ depot, lib, ... }:

let
  inherit (depot.nix.runTestsuite)
    runTestsuite
    it
    assertEq
    assertThrows
    ;

  tree-ex = depot.nix.readTree {} ./test-example;

  example = it "corresponds to the example" [
    (assertEq "third_party attrset"
      (lib.isAttrs tree-ex.third_party
      && (! lib.isDerivation tree-ex.third_party))
      true)
    (assertEq "third_party attrset other attribute"
      tree-ex.third_party.favouriteColour
      "orange")
    (assertEq "rustpkgs attrset aho-corasick"
      tree-ex.third_party.rustpkgs.aho-corasick
      "aho-corasick")
    (assertEq "rustpkgs attrset serde"
      tree-ex.third_party.rustpkgs.serde
      "serde")
    (assertEq "tools cheddear"
      "cheddar"
      tree-ex.tools.cheddar)
    (assertEq "tools roquefort"
      tree-ex.tools.roquefort
      "roquefort")
  ];

in runTestsuite "readTree" [
  example
]
