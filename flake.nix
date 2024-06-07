{
  description = "Zink it links your files!";

  # nixpkgs
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  # inputs.nixpkgs-zig-0_13.url = "github:ExpidusOS/nixpkgs/feat/zig-0.13";

  # devenv.sh
  # inputs.devenv.url = "github:cachix/devenv";
  # nixConfig.extra-trusted-public-keys = "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=";
  # nixConfig.extra-substituters = "https://devenv.cachix.org";

  outputs = { self, nixpkgs, ... }@inputs:
    (fn: builtins.foldl'
      (acc: s: nixpkgs.legacyPackages.${s}.lib.recursiveUpdate
        acc
        (builtins.mapAttrs (_: value: { ${s} = value; }) (fn s)))
      { })
      (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          # Broken :\ # pkgs-zig-0_13 = inputs.nixpkgs-zig-0_13.legacyPackages.${system};
          fs = pkgs.lib.fileset;

          inherit (pkgs) zig zls;

          buildDeps = {
            inherit zig;
          };

          name = "zink";
          version = "0.0.1";
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
            buildInputs = builtins.attrValues buildDeps;
            buildPhase = ''
              zig build -Doptimize=ReleaseSmall -Dtarget=${system}
            '';
            installPhase = ''
              mv zig-out $out;
            '';
          };
        in
        {
          apps.${name} = { type = "app"; program = "${pkg}/bin/zink"; };
          apps.default = self.apps.${system}.${name};
          packages.${name} = pkg;
          packages.default = self.packages.${system}.${name};

          devShells.default = pkgs.mkShell {
            buildInputs = builtins.attrValues (buildDeps // {
              inherit zls;
            });
          };

          # devenv.sh
          # packages.devenv-up = self.devShells.${system}.default.config.procfileScript;
          # devShells.default = inputs.devenv.lib.mkShell {
          #   inherit inputs pkgs;
          #   modules = [ (attrs: import ./devenv.nix (attrs // { deps = buildDeps; })) ];
          # };

        }) [ "aarch64-darwin" "aarch64-linux" "x86_64-darwin" "x86_64-linux" ];
}
