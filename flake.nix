{
  description = "FlClashX (pluralplay fork of FlClash) for NixOS: package, overlay and NixOS module with TUN support";

  inputs = {
    # FlClashX needs Flutter >= 3.38 (Dart >= 3.10, see pubspec.lock), which is
    # available on nixos-26.05 and newer. Override with `inputs.nixpkgs.follows`
    # in your own flake to reuse your system nixpkgs.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Upstream sources. Pinned by flake.lock; bump with:
    #   nix flake update flclashx-src
    flclashx-src = {
      url = "github:pluralplay/FlClashX";
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
      # flutter_js ships a prebuilt x86_64 libquickjs_c_bridge_plugin.so,
      # so aarch64 cannot work without changes upstream.
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # ======================================================================
      # HASHES — must be refreshed when upstream changes core/go.sum or the
      # flutter_js git revision in pubspec.lock (see the README notes).
      # ======================================================================
      # Go modules of ./core (same value as in PR #118).
      vendorHash = "sha256-BsFT/KrD8SX3edFtipK/eaJvVopvOCmTiw+Ydh+oa0s=";
      # Git dependencies from pubspec.lock (flutter_js @ c0e10a5d...).
      gitHashes = {
        flutter_js = "sha256-4PgiUL7aBnWVOmz2bcSxKt81BRVMnopabj5LDbtPYk4=";
      };

      lib = nixpkgs.lib;

      # "version: 0.4.2+2026071801" -> "0.4.2"
      version =
        let
          line = lib.findFirst (l: lib.hasPrefix "version:" l) "version: 0.0.0" (
            lib.splitString "\n" (builtins.readFile "${flclashx-src}/pubspec.yaml")
          );
        in
        builtins.head (lib.splitString "+" (lib.removePrefix "version:" (lib.replaceStrings [ " " ] [ "" ] line)));

      # `const String kCoreVersionFromSource = 'v1.19.28';` -> "v1.19.28"
      coreVersion =
        let
          line = lib.findFirst (l: lib.hasInfix "kCoreVersionFromSource" l) "" (
            lib.splitString "\n" (builtins.readFile "${flclashx-src}/lib/core_version.dart")
          );
          m = builtins.match ".*'([^']+)'.*" line;
        in
        if m == null then "unknown" else builtins.head m;

      # --- Go core (mihomo wrapper, started by the app as FlClashCore) ----------
      mkCore =
        pkgs:
        pkgs.buildGoModule {
          pname = "flclashx-core";
          inherit version vendorHash;
          src = flclashx-src;
          modRoot = "core";
          subPackages = [ "." ];

          # Same as setup.dart: CGO off (the !cgo main.go is the standalone
          # server binary), tag with_gvisor.
          env.CGO_ENABLED = "0";
          tags = [ "with_gvisor" ];
          ldflags = [
            "-s"
            "-w"
            "-X github.com/metacubex/mihomo/constant.Version=${coreVersion}"
          ];

          # The Go module is called "core", the app expects "FlClashCore".
          postInstall = ''
            mv $out/bin/core $out/bin/FlClashCore
          '';

          doCheck = false;

          meta = {
            description = "Mihomo-based core of FlClashX";
            homepage = "https://github.com/pluralplay/FlClashX";
            license = lib.licenses.gpl3Only;
            mainProgram = "FlClashCore";
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
          keybinder3,
          core,
          # When set (by the NixOS module, tunMode.enable), the app's
          # FlClashCore becomes a symlink to this security wrapper
          # (e.g. /run/wrappers/bin/flclashx-core) and the app's
          # "is the core privileged?" check is taught about it.
          coreWrapperPath ? null,
          # Force GTK to use Wayland (GDK_BACKEND=wayland) for every way of
          # starting the app (menu, tray autostart, terminal).
          waylandBackend ? false,
        }:
        flutter.buildFlutterApplication {
          pname = "flclashx";
          inherit version gitHashes;
          src = flclashx-src;

          # IFD: converts pubspec.lock (YAML) to JSON at eval time.
          autoPubspecLock = "${flclashx-src}/pubspec.lock";

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
            keybinder3 # hotkey_manager_linux
          ];

          # Libraries that are dlopen()ed / prebuilt (flutter_js bundles a
          # prebuilt libquickjs_c_bridge_plugin.so needing libstdc++).
          runtimeDependencies = [
            libayatana-appindicator
            stdenv.cc.cc
          ];

          extraWrapProgramArgs = lib.optionalString waylandBackend "--set GDK_BACKEND wayland";

          # linux/CMakeLists.txt installs ../libclash/linux/FlClashCore into the
          # bundle, so it has to exist at build time (upstream's setup.dart
          # puts it there).
          preBuild = ''
            mkdir -p libclash/linux
            cp ${core}/bin/FlClashCore libclash/linux/FlClashCore
          '';

          # TUN on NixOS: the app tries `sudo chown root && chmod +s` on its core,
          # which cannot work inside /nix/store. With a security wrapper in
          # place, report the core as already privileged instead.
          postPatch = lib.optionalString (coreWrapperPath != null) ''
            substituteInPlace lib/common/system.dart --replace-fail \
              "final result = await Process.run('stat', ['-c', '%U:%G %A', corePath]);" \
              "try {
                if ((await File(appPath.corePath).resolveSymbolicLinks()).startsWith('/run/wrappers/')) return true;
              } catch (_) {}
              final result = await Process.run('stat', ['-c', '%U:%G %A', corePath]);"
          '';

          postInstall = ''
            # The builder symlinks every top-level file of the bundle into
            # $out/bin; the core is not meant to be on PATH.
            rm -f $out/bin/FlClashCore

            # The app starts <dir of its executable>/FlClashCore.
            ln -sfn ${if coreWrapperPath == null then "${core}/bin/FlClashCore" else coreWrapperPath} \
              $out/app/$pname/FlClashCore

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
            inherit core;
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
        pkgs.callPackage appFn {
          core = mkCore pkgs;
        };
    in
    {
      packages = forAllSystems (pkgs: rec {
        flclashx = mkApp pkgs;
        flclashx-core = mkCore pkgs;
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
          wrapperName = "flclashx-core";
          wrapperPath = "${config.security.wrapperDir}/${wrapperName}";

          # With TUN, DNS replies hijacked by the core come back on the TUN
          # device with a LAN source address (e.g. the router), which the NixOS
          # reverse path filter treats as spoofed and drops. Exempt only the
          # TUN device from that check; all other interfaces stay filtered.
          # (Pointless if the filter is disabled anyway.)
          fixRpfilter =
            cfg.tunMode.enable
            && cfg.tunMode.exemptFromReversePathFilter
            && config.networking.firewall.checkReversePath != false;
        in
        {
          options.programs.flclashx = {
            enable = lib.mkEnableOption "FlClashX, a Mihomo-based proxy client";

            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.stdenv.hostPlatform.system}.flclashx;
              defaultText = lib.literalExpression "flclashx.packages.\${system}.flclashx";
              description = "The FlClashX package to use (must expose `passthru.core`).";
            };

            wayland.enable = lib.mkEnableOption ''
              forcing the Wayland backend (GDK_BACKEND=wayland) for FlClashX.
              Leave it off on X11 sessions, the app will not start there
            '';

            tunMode = {
              enable = lib.mkEnableOption ''
                TUN mode. The core is started through a security wrapper that gives
                it the needed network capabilities, so FlClashX never asks for a
                sudo password (which cannot work on NixOS anyway)
              '';

              setuid = lib.mkEnableOption ''
                a setuid-root wrapper instead of file capabilities. Less secure and
                the core then runs as root; use only if the default capability
                wrapper does not work for you
              '';

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
            environment.systemPackages = [
              (cfg.package.override {
                coreWrapperPath = if cfg.tunMode.enable then wrapperPath else null;
                waylandBackend = cfg.wayland.enable;
              })
            ];

            security.wrappers.${wrapperName} = lib.mkIf cfg.tunMode.enable {
              source = "${cfg.package.core}/bin/FlClashCore";
              owner = "root";
              group = "root";
              setuid = cfg.tunMode.setuid;
              # The same set sing-box / Throne use for TUN + process matching.
              capabilities = lib.mkIf (!cfg.tunMode.setuid) "cap_net_admin,cap_net_raw,cap_net_bind_service,cap_sys_ptrace,cap_dac_read_search+ep";
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
