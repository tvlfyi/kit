# This program is used as a Gerrit hook to trigger builds on
# Buildkite, Sourcegraph reindexing and other maintenance tasks.
{ ciBuilds, depot, ... }:

let
  inherit (builtins) toFile toJSON;
in depot.nix.buildTypedGo.program {
  name = "besadii";
  srcs = [ ./main.go2 ];
}
