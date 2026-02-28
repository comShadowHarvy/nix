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
      });

      # convenience defaultPackage for `nix build`
      defaultPackage.x86_64-linux = packages.x86_64-linux.compose;

      # expose the original module as a NixOS module so it can still be used
      nixosModules = {
        default = import ./nixos-module.nix;
      };
    };
}
