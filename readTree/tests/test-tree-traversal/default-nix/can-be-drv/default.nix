{ ... }:
derivation {
  name = "im-a-drv";
  system = builtins.currentSystem;
  builder = "/bin/sh";
  args = [ "-c" ''echo "" > $out'' ];
}
