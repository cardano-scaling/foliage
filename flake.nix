{
  description =
    "Foliage is a tool to create custom Haskell package repositories, in a fully reproducible way.";

  inputs = {
    nixpkgs.follows = "haskell-nix/nixpkgs-unstable";
    haskell-nix.url = "github:input-output-hk/haskell.nix";
    haskell-nix.inputs.hackage.follows = "hackage-nix";
    hackage-nix.url = "github:input-output-hk/hackage.nix";
    hackage-nix.flake = false;
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { nixpkgs, flake-utils, haskell-nix, ... }:
    let
      systems = [
        "x86_64-linux"
        "x86_64-darwin"
        # TODO switch back on when ci.iog.io has builders for aarch64-linux
        # "aarch64-linux"
        "aarch64-darwin"
      ];
    in
    flake-utils.lib.eachSystem systems (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          inherit (haskell-nix) config;
          overlays = [ haskell-nix.overlay ];
        };
        inherit (pkgs) lib;

        project = pkgs.haskell-nix.cabalProject' {
          src = ./.;
          compiler-nix-name = "ghc94";
          shell.tools = {
            cabal = "latest";
            hlint = "latest";
            haskell-language-server = "latest";
            fourmolu = "0.14.0.0";
          };
        };

        flake = project.flake (
          lib.attrsets.optionalAttrs (system == "x86_64-linux")
            { crossPlatforms = p: [ p.musl64 ]; }
        );

        # Wrap the foliage executable with the needed dependencies in PATH.
        # See #71.
        wrapExe = drv:
          pkgs.runCommand "foliage"
            {
              nativeBuildInputs = [ pkgs.makeWrapper ];
            } ''
            mkdir -p $out/bin
            makeWrapper ${drv}/bin/foliage $out/bin/foliage \
                --prefix PATH : ${with pkgs; lib.makeBinPath [ curl patch ]}:$out/bin
          '';

      in

      flake // {
        inherit project;

        # This is way too much boilerplate. I only want the default package to
        # be the main exe (package or app) and "static" the static version on
        # the systems where it is available.

        apps = { default = flake.apps."foliage:exe:foliage"; }
        // lib.attrsets.optionalAttrs (system == "x86_64-linux")
          { static = wrapExe flake.apps."x86_64-unknown-linux-musl:foliage:exe:foliage"; }
        // lib.attrsets.optionalAttrs (system == "aarch64-linux")
          { static = wrapExe flake.apps."aarch64-multiplatform-musl:foliage:exe:foliage"; };

        packages = { default = flake.packages."foliage:exe:foliage"; }
        // lib.attrsets.optionalAttrs (system == "x86_64-linux")
          { static = flake.packages."x86_64-unknown-linux-musl:foliage:exe:foliage"; }
        ;
      }
    );

  nixConfig = {
    extra-substituters = [
      "https://cache.iog.io"
    ];
    extra-trusted-public-keys = [
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
    ];
  };
}
