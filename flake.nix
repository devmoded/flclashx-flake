{
  description = "FlClashX (pluralplay fork of FlClash) for NixOS: package, overlay and NixOS module with TUN support";

  inputs = {
    # FlClashX 0.5.8 builds with the Flutter 3.47 toolchain (language version
    # >= 3.10.0 in its pubspec.yaml), which is available on nixos-unstable.
    # Override with `inputs.nixpkgs.follows` in your own flake to reuse your
    # system nixpkgs.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Upstream sources. Pinned by flake.lock; bump with:
    #   nix flake update flclashx-src
    flclashx-src = {
      url = "github:pluralplay/FlClashX/v0.5.8";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flclashx-src,
    }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      lib = nixpkgs.lib;

      # ======================================================================
      # HASHES — refresh when upstream changes the corresponding lock file.
      # Use lib.fakeHash, build, and paste the `got:` value.
      # ======================================================================

      # core/go.sum
      vendorHash = "sha256-/lx1/OfWcHS0GFXgvqx/jUxOoNmUBukyRWDBFxQNoMw=";
      # services/helper/Cargo.lock
      helperCargoHash = "sha256-M7m+rs96S4CkQK/mnJ+5IcHXQKMl3Yp2bovdpwc+Nn4=";
      # plugins/rust_api/rust/Cargo.lock
      rustApiCargoHash = "sha256-5ie8iNeumnThUHet6BULxlqEygVfbE+YoZ9SQxk9Lrc=";
      # Git dependencies from pubspec.lock.
      gitHashes = {
        launch_at_startup = "sha256-vr679QsLuIYyW9gaAHA4Uya4f6spWHViijDJSEnfrPw=";
      };

      # "version: 0.5.8+2026111801" -> "0.5.8"
      version =
        let
          line = lib.findFirst (l: lib.hasPrefix "version:" l) "version: 0.0.0" (
            lib.splitString "\n" (builtins.readFile "${flclashx-src}/pubspec.yaml")
          );
        in
        builtins.head (lib.splitString "+" (lib.removePrefix "version:" (lib.replaceStrings [ " " ] [ "" ] line)));

      # Read a scalar out of build_config.yaml without a YAML parser:
      #   core_version: v1.19.34  ->  v1.19.34
      readBuildConfig =
        key:
        let
          line = lib.findFirst (l: lib.hasPrefix "${key}:" l) "" (
            lib.splitString "\n" (builtins.readFile "${flclashx-src}/build_config.yaml")
          );
          m = builtins.match "${key}:[[:space:]]*([^[:space:]]+).*" line;
        in
        if m == null then throw "build_config.yaml has no ${key}" else builtins.head m;

      coreVersion = readBuildConfig "core_version";
      coreName = readBuildConfig "core_name";
      helperName = readBuildConfig "helper_name";

      # --- Go core (mihomo wrapper, started by the app/helper as FlClashCore) ---
      mkCore =
        pkgs:
        pkgs.buildGo126Module {
          pname = "flclashx-core";
          inherit version vendorHash;
          src = flclashx-src;
          modRoot = "core";

          # 0.5.x moved the main package from ./core to ./core/cmd/core.
          # Building the module root produces an `ar` archive, which the helper
          # cannot exec.
          subPackages = [ "./cmd/core" ];

          # Same as setup.dart: CGO off (the !cgo main.go is the standalone
          # server binary), tag with_gvisor.
          env.CGO_ENABLED = "0";
          tags = [ "with_gvisor" ];
          ldflags = [
            "-s"
            "-w"
            "-X github.com/metacubex/mihomo/constant.Version=${coreVersion}"
          ];

          # The helper verifies this exact binary against manifest.json and the
          # SHA-256 embedded at helper build time. Strip/patchelf would change it.
          dontStrip = true;
          dontPatchELF = true;

          # The Go module is called "core", the app expects "FlClashCore".
          postInstall = ''
            mv $out/bin/core $out/bin/${coreName}
          '';

          doCheck = false;

          meta = {
            description = "Mihomo-based core of FlClashX";
            homepage = "https://github.com/pluralplay/FlClashX";
            license = lib.licenses.gpl3Only;
            mainProgram = coreName;
            platforms = systems;
          };
        };

      # SHA-256 of the core binary, consumed by the helper at build time and
      # written to libclash/linux/manifest.json for the app.
      coreSha256Command = core: ''
        sha256sum ${core}/bin/${coreName} | cut -d' ' -f1 | tr -d '\n'
      '';

      # --- Rust helper (root systemd service, starts the core for TUN) ----------
      mkHelper =
        pkgs: core:
        pkgs.rustPlatform.buildRustPackage {
          pname = "flclashx-helper";
          inherit version;
          src = "${flclashx-src}/services/helper";
          cargoHash = helperCargoHash;

          # build.rs turns these into the CORE_SHA256/CORE_NAME constants.
          preBuild = ''
            export CORE_SHA256="$(${coreSha256Command core})"
            export CORE_NAME="${coreName}"
          '';

          postInstall = ''
            mv $out/bin/helper $out/bin/${helperName}
          '';

          doCheck = false;

          meta = {
            description = "Privileged helper of FlClashX (starts the core for TUN mode)";
            homepage = "https://github.com/pluralplay/FlClashX";
            license = lib.licenses.gpl3Only;
            mainProgram = helperName;
            platforms = systems;
          };
        };

      # --- Rust API (native asset, librust_api.so) -------------------------------
      mkRustApi =
        pkgs:
        pkgs.rustPlatform.buildRustPackage {
          pname = "flclashx-rust-api";
          inherit version;
          src = "${flclashx-src}/plugins/rust_api/rust";
          cargoHash = rustApiCargoHash;

          doCheck = false;

          installPhase = ''
            runHook preInstall
            install -Dm755 "$(find . -name 'librust_api.so' -type f | head -n1)" \
              $out/lib/librust_api.so
            runHook postInstall
          '';

          meta = {
            description = "Rust API library of FlClashX (IPC, hotkeys, JS scripts, editor)";
            homepage = "https://github.com/pluralplay/FlClashX";
            license = lib.licenses.gpl3Only;
            platforms = systems;
          };
        };

      # --- Flutter GUI -----------------------------------------------------------
      appFn =
        {
          lib,
          stdenv,
          flutter,
          makeDesktopItem,
          copyDesktopItems,
          imagemagick,
          gtk3,
          glib,
          gdk-pixbuf,
          cairo,
          pango,
          atk,
          harfbuzz,
          libepoxy,
          libayatana-appindicator,
          libx11,
          core,
          helper,
          rustApi,
          # pubspec.lock converted to an attrset, with the root package's
          # language version taken from pubspec.yaml (>=3.10.0).
          pubspecLock,
          # Force GTK to use Wayland (GDK_BACKEND=wayland) for every way of
          # starting the app (menu, tray autostart, terminal).
          waylandBackend ? false,
        }:
        flutter.buildFlutterApplication {
          pname = "flclashx";
          inherit version gitHashes pubspecLock;
          src = flclashx-src;

          # sqlcipher_flutter_libs 0.7.0+eol is an empty stub with no
          # linux/CMakeLists.txt, so nixpkgs' builder (which rewrites a
          # prebuilt-binary URL in that file) fails. The package needs no
          # native sources now.
          customSourceBuilders = {
            sqlcipher_flutter_libs = { src, ... }: src;
          };

          # The dart-defines the upstream release build passes (setup.dart).
          flutterBuildFlags = [
            "--dart-define=APP_ENV=stable"
            "--dart-define=APP_VERSION=${version}"
            "--dart-define=CORE_VERSION=${coreVersion}"
          ];

          nativeBuildInputs = [
            copyDesktopItems
            imagemagick
          ];

          buildInputs = [
            gtk3
            glib
            gdk-pixbuf
            cairo
            pango
            atk
            harfbuzz
            libepoxy
            libayatana-appindicator # tray_manager
            libx11 # linux/CMakeLists.txt: pkg_check_modules(X11 REQUIRED)
          ];

          # Libraries that are dlopen()ed / loaded by native assets.
          runtimeDependencies = [
            libayatana-appindicator
            stdenv.cc.cc
          ];

          # Space-joined, not concatenated: a leading space inside an indented
          # string ('' ...'') is stripped as indentation, which glued the two
          # arguments together ("wayland--suffix") when Wayland was enabled.
          extraWrapProgramArgs = lib.concatStringsSep " " (
            lib.optional waylandBackend "--set GDK_BACKEND wayland"
            ++ [
              # flutter_rust_bridge opens librust_api.so by bare name
              # (DynamicLibrary.open('librust_api.so')). The Flutter engine does
              # have $ORIGIN in its RUNPATH, but keep the bundle's lib/ on
              # LD_LIBRARY_PATH so this also works if the loader is invoked from
              # an object without that RUNPATH.
              "--suffix LD_LIBRARY_PATH : \"$out/app/flclashx/lib\""
            ]
          );

          # 0.5.x builds core/helper/rust_api from Dart native-asset hooks,
          # which need network and rustup in the sandbox. Disable the hooks and
          # provide the artifacts ourselves.
          postPatch = ''
            substituteInPlace pubspec.yaml \
              --replace-fail "      build_assets: true" "      build_assets: false"
          '';

          # linux/CMakeLists.txt installs these three from ../libclash/linux.
          preBuild = ''
            mkdir -p libclash/linux
            cp ${core}/bin/${coreName} libclash/linux/${coreName}
            cp ${helper}/bin/${helperName} libclash/linux/${helperName}
            printf '{"coreSha256":"%s"}\n' "$(${coreSha256Command core})" \
              > libclash/linux/manifest.json
          '';

          postInstall = ''
            # The builder symlinks every top-level file of the bundle into
            # $out/bin; these are not meant to be on PATH.
            rm -f $out/bin/${coreName} $out/bin/${helperName} $out/bin/manifest.json

            # Loaded at runtime by flutter_rust_bridge (see extraWrapProgramArgs).
            install -Dm755 ${rustApi}/lib/librust_api.so \
              $out/app/flclashx/lib/librust_api.so

            # The source icon is 1707x1707, which hicolor has no directory for.
            for s in 128 256 512; do
              mkdir -p $out/share/icons/hicolor/''${s}x''${s}/apps
              magick assets/images/icon.png -resize ''${s}x''${s} \
                $out/share/icons/hicolor/''${s}x''${s}/apps/FlClashX.png
            done
          '';

          desktopItems = [
            (makeDesktopItem {
              # = APPLICATION_ID in linux/CMakeLists.txt, so Wayland app-id matches
              name = "com.follow.clashx";
              desktopName = "FlClashX";
              genericName = "Proxy client";
              comment = "Multi-platform proxy client based on Mihomo (Clash.Meta)";
              exec = "FlClashX";
              icon = "FlClashX";
              terminal = false;
              categories = [ "Network" ];
              keywords = [
                "FlClashX"
                "Clash"
                "Proxy"
                "VPN"
              ];
              startupWMClass = "com.follow.clashx";
            })
          ];

          passthru = {
            inherit
              core
              helper
              rustApi
              ;
          };

          meta = {
            description = "Fork of FlClash: multi-platform proxy client based on Mihomo, open source and ad-free";
            homepage = "https://github.com/pluralplay/FlClashX";
            license = lib.licenses.gpl3Only;
            mainProgram = "FlClashX";
            platforms = systems;
          };
        };

      mkApp =
        pkgs:
        let
          core = mkCore pkgs;
          helper = mkHelper pkgs core;
          rustApi = mkRustApi pkgs;

          # nixpkgs takes pubspec.lock's `sdks.dart` as the *root package's*
          # language version. Pub writes the minimum required by the locked
          # dependency set there (3.13.2), while the root pubspec.yaml declares
          # >=3.10.0, and 0.5.8's source uses the `final` parameter modifier that
          # Dart 3.13 rejects. Use the root package's real language version.
          lock = lib.importJSON (
            pkgs.runCommand "flclashx-pubspec-lock" { nativeBuildInputs = [ pkgs.yq ]; } ''
              yq . ${flclashx-src}/pubspec.lock > "$out"
            ''
          );
          pubspecLock = lock // {
            sdks = lock.sdks // {
              dart = ">=3.10.0 <4.0.0";
            };
          };
        in
        pkgs.callPackage appFn {
          inherit
            core
            helper
            rustApi
            pubspecLock
            ;
        };
    in
    {
      packages = forAllSystems (pkgs: rec {
        flclashx = mkApp pkgs;
        flclashx-core = mkCore pkgs;
        flclashx-helper = mkHelper pkgs flclashx-core;
        flclashx-rust-api = mkRustApi pkgs;
        default = flclashx;
      });

      overlays.default = final: _prev: {
        flclashx = self.packages.${final.stdenv.hostPlatform.system}.flclashx;
      };

      nixosModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.programs.flclashx;

          # Only one normal user -> no ambiguity, infer the owner.
          normalUsers = lib.attrNames (
            lib.filterAttrs (_: user: user.isNormalUser or false) config.users.users
          );
          detectedOwner = if lib.length normalUsers == 1 then lib.head normalUsers else null;
          owner = if cfg.tunMode.user != null then cfg.tunMode.user else detectedOwner;

          # Lazy-evaluation safety: the scripts below are only used when owner
          # is non-null, but escapeShellArg must not see null anyway.
          ownerName = if owner == null then "root" else owner;

          # The helper does chmod 0660 but not chown: the socket group is the
          # helper process' primary group, so the unit sets Group to this.
          ownerGroup =
            if owner == null then
              "users"
            else
              config.users.users.${owner}.group or "users";

          # With TUN, DNS replies hijacked by the core come back on the TUN
          # device with a LAN source address (e.g. the router), which the NixOS
          # reverse path filter treats as spoofed and drops. Exempt only the
          # TUN device from that check; all other interfaces stay filtered.
          fixRpfilter =
            cfg.tunMode.enable
            && cfg.tunMode.exemptFromReversePathFilter
            && config.networking.firewall.checkReversePath != false;

          helperStartScript = pkgs.writeShellScript "flclashx-helper-start" ''
            export FLCLASH_HELPER_OWNER_UID="$(${pkgs.coreutils}/bin/id -u ${lib.escapeShellArg ownerName})"
            export FLCLASH_HELPER_OWNER_GID="$(${pkgs.coreutils}/bin/id -g ${lib.escapeShellArg ownerName})"
            exec ${cfg.package}/app/flclashx/${helperName}
          '';

          helperSocketGroupScript = pkgs.writeShellScript "flclashx-helper-socket-group" ''
            for _ in $(${pkgs.coreutils}/bin/seq 1 50); do
              [ -S /run/flclashx/helper.sock ] && break
              ${pkgs.coreutils}/bin/sleep 0.1
            done
            if [ -S /run/flclashx/helper.sock ]; then
              ${pkgs.coreutils}/bin/chgrp ${lib.escapeShellArg ownerGroup} \
                /run/flclashx/helper.sock || true
            fi
          '';
        in
        {
          options.programs.flclashx = {
            enable = lib.mkEnableOption "FlClashX, a Mihomo-based proxy client";

            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.stdenv.hostPlatform.system}.flclashx;
              defaultText = lib.literalExpression "flclashx.packages.\${system}.flclashx";
              description = "The FlClashX package to use.";
            };

            wayland.enable = lib.mkEnableOption ''
              forcing the Wayland backend (GDK_BACKEND=wayland) for FlClashX.
              Leave it off on X11 sessions, the app will not start there
            '';

            tunMode = {
              enable = lib.mkEnableOption ''
                TUN mode. A root systemd service (flclashx-helper) starts the core,
                so FlClashX never asks for a sudo password (which cannot work on
                NixOS anyway)
              '';

              user = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = ''
                  User that owns the TUN session. The helper accepts the
                  privileged-core requests from this user only, and the helper
                  socket is made accessible to their group.

                  Defaults to the only normal user on the system; set it
                  explicitly if there are several (or none).
                '';
              };

              exemptFromReversePathFilter = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = ''
                  Exempt the TUN device from the NixOS firewall reverse path
                  filter. Without this, DNS replies handled by the core are
                  dropped and name resolution under TUN becomes very slow.
                  Supports the iptables and nftables firewall backends.
                '';
              };

              interfaceName = lib.mkOption {
                type = lib.types.str;
                default = "FlClashX";
                description = "Name of the TUN device (the app's default; change only if you changed it in the app).";
              };
            };
          };

          config = lib.mkIf cfg.enable {
            assertions = [
              {
                assertion = !cfg.tunMode.enable || owner != null;
                message = ''
                  programs.flclashx.tunMode.user must be set when TUN mode is
                  enabled: the system has no single normal user to infer it from.
                '';
              }
            ];

            environment.systemPackages = [
              (cfg.package.override {
                waylandBackend = cfg.wayland.enable;
              })
            ];

            systemd.services.flclashx-helper = lib.mkIf (cfg.tunMode.enable && owner != null) {
              description = "FlClashX helper (starts the core for TUN mode)";
              wantedBy = [ "multi-user.target" ];
              wants = [ "network-online.target" ];
              after = [
                "network-online.target"
                "nftables.service"
                "iptables.service"
              ];
              startLimitIntervalSec = 60;
              startLimitBurst = 5;

              serviceConfig = {
                Type = "simple";
                ExecStart = helperStartScript;
                ExecStartPost = helperSocketGroupScript;
                User = "root";
                Group = ownerGroup;
                RuntimeDirectory = "flclashx";
                RuntimeDirectoryMode = "0755";
                Restart = "on-failure";
                RestartSec = 5;
              };
            };

            # iptables backend (NixOS default). The chain only exists when the
            # kernel supports rpfilter, hence the tolerant `|| true`.
            networking.firewall.extraCommands =
              lib.mkIf (fixRpfilter && config.networking.firewall.backend == "iptables")
                ''
                  ip46tables -t mangle -I nixos-fw-rpfilter -i ${cfg.tunMode.interfaceName} -j RETURN 2>/dev/null || true
                '';

            # nftables backend.
            networking.firewall.extraReversePathFilterRules =
              lib.mkIf (fixRpfilter && config.networking.firewall.backend == "nftables")
                ''
                  iifname "${cfg.tunMode.interfaceName}" accept
                '';
          };
        };
    };
}
