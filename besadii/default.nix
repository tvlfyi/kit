# This program is used as a Gerrit hook to trigger builds on
# Buildkite, Sourcegraph reindexing and other maintenance tasks.
{ depot, ... }:

let
  inherit (builtins) toFile toJSON;
in depot.nix.buildGo.program {
  name = "besadii";
  srcs = [ ./main.go ];
}
