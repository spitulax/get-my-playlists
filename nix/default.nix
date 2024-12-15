{ stdenv
, lib
, odin

, debug ? false
}:
let
  version = with lib;
    (pipe (readFile ../Makefile) [
      (splitString "\n")
      (filter (hasPrefix "PROG_VERSION := "))
      head
      (splitString "PROG_VERSION := ")
      last
    ]);
in
stdenv.mkDerivation rec {
  pname = "get-my-playlists";
  inherit version;
  src = lib.cleanSource ./..;

  nativeBuildInputs = [
    odin
  ];

  buildInputs = [

  ];

  buildPhase = ''
    runHook preBuild

    make ${if debug then "debug" else "release"}

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 build/${pname} -t $out/bin

    runHook postInstall
  '';

}
