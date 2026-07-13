{
  description = "mlqs — native QML/Quickshell mail client (Go daemon + vendored UI)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      daemon = pkgs.buildGoModule {
        pname = "mlqs";
        version = "0.1.0";
        src = ./.;
        vendorHash = "sha256-cR5w5qdIKJei51Z7t7EHC4N/jNg4g9vYrf/RGJUe0F8=";
        subPackages = [ "." ];
        postInstall = ''
          mkdir -p $out/share/mlqs
          cp -r ui $out/share/mlqs/ui
        '';
        meta.mainProgram = "mlqs";
      };

      client = pkgs.writeShellApplication {
        name = "mlqs-client";
        runtimeInputs = [ daemon pkgs.quickshell pkgs.procps pkgs.coreutils pkgs.xdg-utils pkgs.wl-clipboard ];
        text = ''
          # QsLib resolution: a locally-managed design system (dotfiles) wins;
          # everyone else falls back to the vendored snapshot in the package
          export QML2_IMPORT_PATH="$HOME/.local/share/qml:${daemon}/share/mlqs/ui/vendor''${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
          sock="$XDG_RUNTIME_DIR/mlqs.sock"
          alive=""
          for pid in $(pgrep -x mlqs 2>/dev/null); do
            # a zombie (unreaped child) matches pgrep but serves nothing
            case "$(ps -o stat= -p "$pid" 2>/dev/null)" in Z*|"") ;; *) alive=1 ;; esac
          done
          if [ -z "$alive" ]; then
            rm -f "$sock"
            setsid nohup ${daemon}/bin/mlqs >/tmp/mlqs-daemon.log 2>&1 </dev/null &
          fi
          for _ in $(seq 1 150); do [ -S "$sock" ] && break; sleep 0.1; done
          exec qs -p "${daemon}/share/mlqs/ui"
        '';
      };
    in {
      packages.${system} = {
        mlqs = daemon;
        mlqs-client = client;
        default = client;
      };
    };
}
