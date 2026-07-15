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
        # Embed the build's git rev so the daemon can detect newer builds.
        ldflags = [ "-X main.gitRev=${self.rev or ""}" ];
        postInstall = ''
          mkdir -p $out/share/mlqs
          cp -r ui $out/share/mlqs/ui
        '';
        meta.mainProgram = "mlqs";
      };

      client = pkgs.writeShellApplication {
        name = "mlqs-client";
        # imagemagick: image yanks are png-normalized; python3: rich yank
        # inlines images as data URIs; util-linux: setsid-detached wl-copy
        runtimeInputs = [ daemon pkgs.quickshell pkgs.procps pkgs.coreutils pkgs.xdg-utils
                          pkgs.wl-clipboard pkgs.imagemagick pkgs.python3 pkgs.util-linux ];
        text = ''
          # QsLib resolution: a locally-managed design system (dotfiles) wins;
          # everyone else falls back to the vendored snapshot in the package
          export QML2_IMPORT_PATH="$HOME/.local/share/qml:${daemon}/share/mlqs/ui/vendor''${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
          sock="$XDG_RUNTIME_DIR/mlqs.sock"

          # serialize the daemon aliveness check + spawn: concurrent launches
          # used to each see "no daemon" and spawn duplicates
          exec 9>"$XDG_RUNTIME_DIR/mlqs-launch.lock"
          flock 9
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

          # single-instance UI: a q-dismissed window is hidden (visible=false),
          # invisible to the compositor — blind spawns stack silent UI
          # processes. Summon through the daemon and trust only its ACK:
          # "clients" counts UIs actually connected to the socket. Zero means
          # every surviving UI process is a zombie (alive but deaf to the
          # summon broadcast) — reap them all and cold-start.
          if printf '{"type":"summonui"}\n' | python3 -c '
          import json, os, socket, sys
          s = socket.socket(socket.AF_UNIX)
          s.settimeout(1.5)
          s.connect(os.environ["XDG_RUNTIME_DIR"] + "/mlqs.sock")
          s.sendall(sys.stdin.buffer.read())
          buf = b""
          while b"summonack" not in buf:
              d = s.recv(65536)
              if not d:
                  sys.exit(1)
              buf += d
          for line in buf.splitlines():
              try:
                  e = json.loads(line)
              except ValueError:
                  continue
              if e.get("type") == "summonack":
                  sys.exit(0 if e.get("clients", 0) >= 1 else 1)
          sys.exit(1)
          ' 2>/dev/null; then
            exit 0
          fi
          for pid in $(pgrep -f "quickshell.* -p .*mlqs/ui" || true); do
            kill "$pid" 2>/dev/null || true
          done
          sleep 0.3
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
