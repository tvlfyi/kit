{ depot, ... }:

let
  inherit (depot.nix.runTestsuite)
    runTestsuite
    it
    assertEq
    ;

  inherit (depot.nix.stateMonad)
    pure
    run
    join
    fmap
    bind
    get
    set
    modify
    after
    for_
    getAttr
    setAttr
    modifyAttr
    ;

  runStateIndependent = run (throw "This should never be evaluated!");
in

runTestsuite "stateMonad" [
  (it "behaves correctly independent of state" [
    (assertEq "pure" (runStateIndependent (pure 21)) 21)
    (assertEq "join pure" (runStateIndependent (join (pure (pure 42)))) 42)
    (assertEq "fmap pure" (runStateIndependent (fmap (builtins.mul 2) (pure 21))) 42)
    (assertEq "bind pure" (runStateIndependent (bind (pure 12) (x: pure x))) 12)
  ])
  (it "behaves correctly with an integer state" [
    (assertEq "get" (run 42 get) 42)
    (assertEq "after set get" (run 21 (after (set 42) get)) 42)
    (assertEq "after modify get" (run 21 (after (modify (builtins.mul 2)) get)) 42)
    (assertEq "fmap get" (run 40 (fmap (builtins.add 2) get)) 42)
    (assertEq "stateful sum list"
      (run 0 (after
        (for_
          [
            15
            12
            10
            5
          ]
          (x: modify (builtins.add x)))
        get))
      42)
  ])
  (it "behaves correctly with an attr set state" [
    (assertEq "getAttr" (run { foo = 42; } (getAttr "foo")) 42)
    (assertEq "after setAttr getAttr"
      (run { foo = 21; } (after (setAttr "foo" 42) (getAttr "foo")))
      42)
    (assertEq "after modifyAttr getAttr"
      (run { foo = 10.5; }
        (after
          (modifyAttr "foo" (builtins.mul 4))
          (getAttr "foo")))
      42)
    (assertEq "fmap getAttr"
      (run { foo = 21; } (fmap (builtins.mul 2) (getAttr "foo")))
      42)
    (assertEq "after setAttr to insert getAttr"
      (run { } (after (setAttr "foo" 42) (getAttr "foo")))
      42)
    (assertEq "insert permutations"
      (run
        {
          a = 2;
          b = 3;
          c = 5;
        }
        (after
          (bind get
            (state:
              let
                names = builtins.attrNames state;
              in
              for_ names (name1:
                for_ names (name2:
                  # this is of course a bit silly, but making it more cumbersome
                  # makes sure the test exercises more of the code.
                  (bind (getAttr name1)
                    (value1:
                      (bind (getAttr name2)
                        (value2:
                          setAttr "${name1}_${name2}" (value1 * value2)))))))))
          get))
      {
        a = 2;
        b = 3;
        c = 5;
        a_a = 4;
        a_b = 6;
        a_c = 10;
        b_a = 6;
        b_b = 9;
        b_c = 15;
        c_c = 25;
        c_a = 10;
        c_b = 15;
      }
    )
  ])
]
