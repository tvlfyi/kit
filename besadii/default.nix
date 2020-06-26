# This program is used as a git post-update hook to trigger builds on
# sourcehut.
{ ciBuilds, depot, ... }:

let
  inherit (builtins) toFile toJSON;
in depot.nix.buildTypedGo.program {
  name = "besadii";
  srcs = [ ./main.go2 ];

  x_defs = {
    "main.TargetList" = toFile "ci-targets.json" (toJSON ciBuilds.__evaluatable);
  };
}
