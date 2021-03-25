# This program is used as a Gerrit hook to trigger builds on
# Buildkite, Sourcegraph reindexing and other maintenance tasks.
{ depot, ... }:

depot.nix.buildGo.program {
  name = "besadii";
  srcs = [ ./main.go ];
}
