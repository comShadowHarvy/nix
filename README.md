# Project: nix

Minimal instructions to set up, update, and run Docker for this repository.

## Setup

- Clone the repository and enter it:

```bash
git clone <repo-url> nix
cd nix
```

- (Optional) If you use Nix or a development shell, run your usual command, e.g.:

```bash
# enter a development shell if available
nix develop
```

## Run Docker

- Build (if you have a Dockerfile):

```bash
docker build -t myapp .
```

- Run (basic):

```bash
docker run --rm -p 8080:8080 --name myapp myapp
```

- If you use Docker Compose (recommended when present):

```bash
docker compose up -d    # start
docker compose down     # stop
```

Replace ports and service names as needed for your project.

## Update (pull and apply changes)

```bash
git pull origin main
# make changes locally
git add .
git commit -m "Describe changes"
git push origin main
```

## nvim config

The `nvim` directory contains your Neovim configuration. Edit files under `nvim/` and commit them with `git add nvim`.

## Notes

- If this repo previously recorded `nvim` as a submodule, it was converted into a regular tracked directory.
- If you want me to push the recent commits (including this README), tell me and I'll push to `origin main`.

## Enable NixOS module

To enable the declarative Tdarr configuration on your NixOS server (using this flake), add the module and enable `services.tdarr` in your system configuration. Example `flake.nix` usage:

```nix
# in your NixOS system flake or configuration
inputs.nix.url = "github:NixOS/nixpkgs";

outputs = { self, nixpkgs, ... }:
{
	nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
		system = "x86_64-linux";
		modules = [ ./nix/flake.nix?tdarr ]; # imports the tdarr module from this repo
		configuration = {
			services.tdarr.enable = true;
			services.tdarr.smbCreds.user = "myuser";
			services.tdarr.smbCreds.pass = "supersecret";
			# override shares if needed
			services.tdarr.smbShares = {
				hass_share = { path = "//192.168.1.210/share"; auth = "auth"; };
			};
		};
	};
};
```

After updating your flake configuration, apply with:

```bash
nixos-rebuild switch --flake .#myhost
```

The module will ensure autofs maps, SMB credential file, compose file, Docker, and a systemd service to start the Tdarr containers are configured.
