{ self, lib, inputs }: {
  default = final: prev: rec {
    get-my-playlists = final.callPackage ./default.nix { };
    get-my-playlists-debug = get-my-playlists.override { debug = true; };
  };
}
