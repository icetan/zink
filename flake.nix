{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";

    # zig-json.url = "github:berdon/zig-json";
    # zig-json.flake = false;

    # zig-glob.url = "github:iCodeIN/glob-zig";
    # zig-glob.flake = false;
  };

  outputs = { self, nixpkgs, ... }@inputs: let
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
    zigDeps = pkgs.linkFarm "zink-deps" {
      # inherit (inputs) zig-glob-fix; #zig-json;
      # inherit zig-glob-fix;
    };
    shellHook = ''
      ln -sfT ${zigDeps} libs
    '';
    app = pkgs.stdenv.mkDerivation {
      name = "zink";
      src = ./.;
      buildInputs = builtins.attrValues {
        inherit (pkgs) zig;
      };
      buildPhase = ''
        ${shellHook}
        zig build -Drelease-small=true
      '';
      installPhase = ''
        mv zig-out $out;
      '';
    };
  in {
    packages.x86_64-linux.default = app;
    devShells.x86_64-linux.default = pkgs.mkShell {
      buildInputs = app.buildInputs ++ builtins.attrValues {
        inherit (pkgs) zls;
      };
      inherit shellHook;
    };
  };
}
