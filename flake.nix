{
  description = "Flake for nix repo: provides a small package to produce a compiled docker-compose artifact and exports the original NixOS module.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
  };

  outputs = { self, nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" ];
    in
    {
      for system in systems; inherit (nixpkgs) lib;
      packages = lib.genAttrs systems (system: let
        pkgs = import nixpkgs { inherit system; };
      in {
        compose = pkgs.stdenv.mkDerivation {
          pname = "docker-compose-compiled";
          version = "1";
          src = ./.;
          buildInputs = [ pkgs.coreutils ];
          buildPhase = ''
            mkdir -p $out
            if [ -f "${./docker-compose.yml}" ]; then
              cp "${./docker-compose.yml}" $out/docker-compose.yml
            else
              echo "# No docker-compose.yml present in source" > $out/docker-compose.yml
            fi
          '';
          installPhase = ''
            true
          '';
          meta = with pkgs.lib; {
            description = "Copies or compiles a docker-compose.yml into the build output";
            license = licenses.mit;
          };
        };

        setup-tdarr = pkgs.stdenv.mkDerivation {
          pname = "setup-tdarr";
          version = "1";
          src = ./.;
          dontPatchELF = true;
          buildInputs = [ pkgs.coreutils ];
          buildPhase = ''
            mkdir -p $out/bin
            install -m755 ${./setup-tdarr.sh} $out/bin/setup-tdarr
          '';
          meta = with pkgs.lib; {
            description = "Tdarr setup helper script packaged as an executable";
            license = licenses.mit;
          };
        };
      });

      # convenience defaultPackage for `nix build`
      defaultPackage.x86_64-linux = packages.x86_64-linux.compose;

      # devShell for local development with docker tooling
      devShells.x86_64-linux.default = let pkgs = import nixpkgs { system = "x86_64-linux"; }; in pkgs.mkShell {
        buildInputs = [ pkgs.docker pkgs.docker-compose pkgs.lazydocker pkgs.git pkgs.jq ];
        shellHook = ''
          echo "Entering devShell: docker, docker-compose, lazydocker available"
        '';
      };

      apps.x86_64-linux.setup-tdarr = {
        type = "app";
        program = "${packages.x86_64-linux.setup-tdarr}/bin/setup-tdarr";
      };

      # expose the original module as a NixOS module so it can still be used
      nixosModules = {
        default = import ./nixos-module.nix;
        tdarr = import ./modules/tdarr.nix;
      };
    };
}
