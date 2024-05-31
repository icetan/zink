{
  description = "Zink it links your files!";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05-small";
  outputs = { self, nixpkgs }@inputs:
    let
      mkOutput = system: builtins.mapAttrs (_: value: { ${system} = value; });
      zigTargetMap = {

      };
    in
    builtins.foldl'
      (acc: system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          fs = pkgs.lib.fileset;
          name = "zink";
          version = "0.0.0";
          pkg = pkgs.stdenv.mkDerivation {
            name = "${name}-${version}";
            src = fs.toSource {
              root = ./.;
              fileset = fs.unions [
                ./src
                ./vendor
                ./build.zig
                ./build.zig.zon
              ];
            };
            buildInputs = builtins.attrValues {
              inherit (pkgs) zig;
            };
            buildPhase = ''
              zig build -Doptimize=ReleaseSmall -Dtarget=${system}
            '';
            installPhase = ''
              mv zig-out $out;
            '';
          };
        in
        pkgs.lib.recursiveUpdate acc (mkOutput system {
          apps.${name} = { type = "app"; program = "${pkg}/bin/zink"; };
          apps.default = self.apps.${system}.${name};
          packages.${name} = pkg;
          packages.default = self.packages.${system}.${name};
          devShells.default = pkgs.mkShell {
            buildInputs = pkg.buildInputs ++ builtins.attrValues {
              inherit (pkgs) zls;
            };
          };
        }))
      { } [ "aarch64-darwin" "aarch64-linux" "x86_64-darwin" "x86_64-linux" ];
}
