{
  description = "Zink, it links your files!";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs, ... }:
    (
      fn:
      builtins.foldl' (
        acc: s:
        nixpkgs.legacyPackages.${s}.lib.recursiveUpdate acc (
          builtins.mapAttrs (_: value: { ${s} = value; }) (fn s)
        )
      ) { }
    )
      (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          buildDeps = { inherit (pkgs) zig; };
          devDeps = buildDeps // {
            inherit (pkgs) zls;
          };

          pname = "zink";
          version = "0.1.0";
          target = builtins.replaceStrings [ "darwin" ] [ "macos" ] system;
          pkg = pkgs.stdenv.mkDerivation {
            name = "${pname}-${version}";
            inherit pname version target;

            src =
              with pkgs.lib.fileset;
              toSource {
                root = ./.;
                fileset = unions [
                  ./src
                  ./vendor
                  ./build.zig
                  ./build.zig.zon
                ];
              };

            buildInputs = builtins.attrValues buildDeps;

            doCheck = true;
            checkPhase = ''
              zig build test -Dtest-filter=...
            '';

            ZIG_GLOBAL_CACHE_DIR = "/tmp/zig-cache";
            buildPhase = ''
              mkdir -p $ZIG_GLOBAL_CACHE_DIR
              zig build -Doptimize=ReleaseSafe -Dtarget=${target}
            '';

            installPhase = ''
              mv zig-out $out;
            '';
          };
        in
        {
          apps.${pname} = {
            type = "app";
            program = "${pkg}/bin/zink";
          };
          apps.default = self.apps.${system}.${pname};

          packages.${pname} = pkg;
          packages.default = self.packages.${system}.${pname};

          devShells.default = pkgs.mkShell { buildInputs = builtins.attrValues devDeps; };
        }
      )
      [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];
}
