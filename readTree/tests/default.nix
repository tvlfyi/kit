{ depot, lib, ... }:

let
  inherit (depot.nix.runTestsuite)
    runTestsuite
    it
    assertEq
    assertThrows
    ;

  tree-ex = depot.nix.readTree {} ./test-example;

  example = it "corresponds to the README example" [
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

  tree-tl = depot.nix.readTree {} ./test-tree-traversal;

  traversal-logic = it "corresponds to the traversal logic in the README" [
    (assertEq "skip subtree default.nix is read"
      tree-tl.skip-subtree.but
      "the default.nix is still read")
    (assertEq "skip subtree a/default.nix is skipped"
      (tree-tl.skip-subtree ? a)
      false)
    (assertEq "skip subtree b/c.nix is skipped"
      (tree-tl.skip-subtree ? b)
      false)
    (assertEq "skip subtree a/default.nix would be read without .skip-subtree"
      (tree-tl.no-skip-subtree.a)
      "am I subtree yet?")
    (assertEq "skip subtree b/c.nix would be read without .skip-subtree"
      (tree-tl.no-skip-subtree.b.c)
      "cool")

    (assertEq "default.nix attrset is merged with siblings"
      tree-tl.default-nix.no
      "siblings should be read")
    (assertEq "default.nix means sibling isn’t read"
      (tree-tl.default-nix ? sibling)
      false)
    (assertEq "default.nix means subdirs are still read and merged into default.nix"
      (tree-tl.default-nix.subdir.a)
      "but I’m picked up")

    (assertEq "default.nix can be not an attrset"
      tree-tl.default-nix.no-merge
      "I’m not merged with any children")
    (assertEq "default.nix is not an attrset -> children are not merged"
      (tree-tl.default-nix.no-merge ? subdir)
      false)

    (assertEq "default.nix can contain a derivation"
      (lib.isDerivation tree-tl.default-nix.can-be-drv)
      true)
    (assertEq "Even if default.nix is a derivation, children are traversed and merged"
      tree-tl.default-nix.can-be-drv.subdir.a
      "Picked up through the drv")
    (assertEq "default.nix drv is not changed by readTree"
      tree-tl.default-nix.can-be-drv
      (import ./test-tree-traversal/default-nix/can-be-drv/default.nix {}))
  ];

  # these each call readTree themselves because the throws have to happen inside assertThrows
  wrong = it "cannot read these files and will complain" [
    (assertThrows "this file is not a function"
      (depot.nix.readTree {} ./test-wrong-not-a-function).not-a-function)
    # can’t test for that, assertThrows can’t catch this error
    # (assertThrows "this file is a function but doesn’t have dots"
    #   (depot.nix.readTree {} ./test-wrong-no-dots).no-dots-in-function)
  ];

in runTestsuite "readTree" [
  example
  traversal-logic
  wrong
]
