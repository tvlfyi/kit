# magrathea helps you build planets
#
# it is a tool for working with monorepos in the style of tvl's depot
{ pkgs, ... }:

let
  inherit (pkgs)
    stdenv
    chicken
    chickenPackages
    makeWrapper
    git
    nix
    lib
    ;

in
stdenv.mkDerivation {
  name = "magrathea";
  src = ./.;
  dontInstall = true;

  nativeBuildInputs = [ chicken makeWrapper ];
  buildInputs = with chickenPackages.chickenEggs; [
    matchable
    srfi-13
  ];

  propagatedBuildInputs = [ git ];

  buildPhase = ''
    mkdir -p $out/bin
    csc -o $out/bin/mg -host -static ${./mg.scm}
  '';

  fixupPhase = ''
    wrapProgram $out/bin/mg --prefix PATH ${lib.makeBinPath [ nix ]}
  '';
}
