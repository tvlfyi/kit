# This program is used as a git post-update hook to trigger builds on
# sourcehut.
{ depot, ... }:

depot.buildGo.program {
  name = "besadii";
  srcs = [ ./main.go ];
}
