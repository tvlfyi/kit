# magrathea helps you build planets
#
# it is a tool for working with monorepos in the style of tvl's depot
{ pkgs, ... }:

pkgs.stdenv.mkDerivation {
  name = "magrathea";
  src = ./.;
  dontInstall = true;

  nativeBuildInputs = [ pkgs.chicken ];
  buildInputs = with pkgs.chickenPackages.chickenEggs; [
    matchable
    srfi-13
  ];

  propagatedBuildInputs = [ pkgs.git ];

  buildPhase = ''
    mkdir -p $out/bin
    csc -o $out/bin/mg -static ${./mg.scm}
  '';
}
