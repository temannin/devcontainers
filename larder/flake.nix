{
  description = "Larder development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs:
        let
          ruby = pkgs.ruby_3_4;
          # ruby-vips dlopens libvips plus glib/gobject at runtime.
          libPath = pkgs.lib.makeLibraryPath [ pkgs.vips pkgs.glib ];
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              ruby
              git
              gh
              gnumake
              gcc
              pkg-config
              sqlite
              libyaml
              vips
              curl
            ];

            shellHook = ''
              # Keep gems inside the project, isolated from any system Ruby.
              export BUNDLE_PATH="$PWD/vendor/bundle"
              export GEM_HOME="$PWD/vendor/bundle/ruby/${ruby.version.libDir}"
              export PATH="$GEM_HOME/bin:$PATH"
              export LD_LIBRARY_PATH="${libPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
              export DYLD_FALLBACK_LIBRARY_PATH="${libPath}''${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
            '';
          };
        });
    };
}
