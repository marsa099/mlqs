{
  description = "mlqs — native QML/Quickshell mail client (Go daemon + vendored UI)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };

          daemon = pkgs.buildGoModule {
        pname = "mlqs";
        version = "0.1.0";
        src = ./.;
        vendorHash = "sha256-GqJ4Ee7UOiBedaEXfbvOba+EPmozDGil9WwihY+wkt0=";
        subPackages = [ "." "./cmd/mlqs-cli" ];
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
          # niri (the mapped-window check below) lives in the system profile, not
          # this wrapper's runtimeInputs — make it reachable on direct invocation.
          export PATH="/run/current-system/sw/bin:$PATH"
          sock="$XDG_RUNTIME_DIR/mlqs.sock"

          # serialize the daemon aliveness check + spawn: concurrent launches
          # used to each see "no daemon" and spawn duplicates
          exec 9>"$XDG_RUNTIME_DIR/mlqs-launch.lock"
          flock 9

          # replace a daemon from an older build: after a rebuild the stale
          # daemon otherwise persists (and keeps firing updateAvailable) until
          # someone pkills it by hand
          current=$(readlink -f "${daemon}/bin/mlqs")
          for pid in $(pgrep -x mlqs 2>/dev/null); do
            exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null) || continue
            if [ -n "$exe" ] && [ "$exe" != "$current" ]; then
              kill "$pid" 2>/dev/null || true
              # wait for the graceful exit — a half-dead daemon makes the
              # aliveness check below skip the restart
              for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
              kill -9 "$pid" 2>/dev/null || true
            fi
          done

          alive=""
          for pid in $(pgrep -x mlqs 2>/dev/null); do
            # a zombie (unreaped child) matches pgrep but serves nothing
            case "$(ps -o stat= -p "$pid" 2>/dev/null)" in Z*|"") ;; *) alive=1 ;; esac
          done
          if [ -z "$alive" ]; then
            rm -f "$sock"
            # 9>&- everywhere we spawn: children must not inherit the launch
            # lock, or it outlives this script and deadlocks future launches
            setsid nohup ${daemon}/bin/mlqs >/tmp/mlqs-daemon.log 2>&1 </dev/null 9>&- &
          fi
          for _ in $(seq 1 150); do [ -S "$sock" ] && break; sleep 0.1; done

          # Poke summonui and succeed only on the daemon ACK saying at least
          # one OTHER client (a real UI) heard the summon broadcast.
          summon_ok() {
            printf '{"type":"summonui"}\n' | python3 -c '
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
          ' 2>/dev/null
          }

          # A real MAPPED window is the only success signal. A
          # windowless-but-connected UI is exactly the #11 ghost, so trusting
          # the client count (summon_ok) would report success while nothing
          # shows. niri is authoritative; off niri, fall back to summon_ok.
          have_niri=""
          if command -v niri >/dev/null 2>&1; then have_niri=1; fi
          confirm() {
            if [ -n "$have_niri" ]; then
              niri msg --json windows 2>/dev/null | grep -q '"title": *"mlqs"'
            else
              summon_ok
            fi
          }

          # Already showing? niri-jump-or-exec normally focuses a live window
          # before we run; a race (or the off-niri path) can still land here.
          if confirm; then exit 0; fi

          # Nothing mapped → reap every mlqs UI (mapped or windowless orphan)
          # and cold-start, then wait ~5s for a real window; one bounded retry,
          # else give up loudly rather than leave a silent ghost. The launch
          # lock is held across this, so a concurrent launch waits.
          for _ in 1 2; do
            for pid in $(pgrep -f "quickshell.* -p .*mlqs/ui" || true); do
              kill "$pid" 2>/dev/null || true
            done
            sleep 0.3
            setsid nohup qs -p "${daemon}/share/mlqs/ui" 9>&- &
            for _ in $(seq 1 50); do
              if confirm; then exit 0; fi
              sleep 0.1
            done
          done
          echo "mlqs-client: UI did not map after 2 cold starts" >&2
          exit 1
        '';
      };
        in {
          mlqs = daemon;
          mlqs-client = client;
          default = client;
        });
    };
}
