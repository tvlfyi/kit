# This program is used as a Gerrit hook to trigger builds on
# Buildkite and perform other maintenance tasks.
{ depot, ... }:

depot.nix.buildGo.program {
  name = "besadii";
  srcs = [ ./main.go ];
}
