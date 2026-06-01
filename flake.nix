{
  description = "Mutinynet RGB, Ark, and plain LND asset-bridge simulation";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.lnd-src = {
    url = "github:tee8z/lnd/feat/custom-signet-block-time";
    flake = false;
  };
  inputs.blockstreamElectrsSrc = {
    url = "github:Blockstream/electrs/new-index";
    flake = false;
  };

  outputs = { self, nixpkgs, lnd-src, blockstreamElectrsSrc }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system:
          f nixpkgs.legacyPackages.${system});

      linuxArch = pkgs:
        if pkgs.stdenv.hostPlatform.system == "x86_64-linux" then "amd64"
        else if pkgs.stdenv.hostPlatform.system == "aarch64-linux" then "arm64"
        else throw "unsupported system ${pkgs.stdenv.hostPlatform.system}";

      bitcoinArch = pkgs:
        if pkgs.stdenv.hostPlatform.system == "x86_64-linux" then "x86_64-linux-gnu"
        else if pkgs.stdenv.hostPlatform.system == "aarch64-linux" then "aarch64-linux-gnu"
        else throw "unsupported system ${pkgs.stdenv.hostPlatform.system}";

      lndBuildTags = [
        "signrpc"
        "walletrpc"
        "chainrpc"
        "invoicesrpc"
        "neutrinorpc"
        "monitoring"
        "peersrpc"
        "routerrpc"
        "verrpc"
        "wtclientrpc"
        "kvdb_sqlite"
        "kvdb_etcd"
      ];

      mkMutinynetLnd = pkgs:
        pkgs.lnd.overrideAttrs (_old: {
          pname = "lnd-mutinynet";
          version = "0.20.99-beta-custom-signet-block-time";

          src = lnd-src;
          tags = lndBuildTags;
          vendorHash = "sha256-L585Cm7xA44S9tqHo7un+6QiwSFnJw4ksFx0xg7BZzU=";

          doCheck = false;
        });

      mkMutinynetBitcoin = pkgs:
        let
          version = "2fda7bfc027e";
          release = "mutinynet-inq-template-hash";
          arch = bitcoinArch pkgs;
          hashes = {
            x86_64-linux-gnu = "sha256-x2tYoHjj5fzEWX9Q2fnRXajRGl2M8IMatilwMpv7YRU=";
            aarch64-linux-gnu = "sha256-wYcF6emCAuCV4Tu8VUa180+7Tfm/i8NO9FU/bS0daLw=";
          };
        in
        pkgs.stdenv.mkDerivation {
          pname = "bitcoin-mutinynet";
          inherit version;

          src = pkgs.fetchurl {
            url = "https://github.com/benthecarman/bitcoin/releases/download/${release}/bitcoin-${version}-${arch}.tar.gz";
            hash = hashes.${arch};
          };

          sourceRoot = "bitcoin-${version}";
          nativeBuildInputs = [ pkgs.autoPatchelfHook ];
          buildInputs = [ pkgs.stdenv.cc.cc.lib ];

          installPhase = ''
            runHook preInstall
            install -Dm755 bin/bitcoind "$out/bin/bitcoind"
            install -Dm755 bin/bitcoin-cli "$out/bin/bitcoin-cli"
            install -Dm755 bin/bitcoin-tx "$out/bin/bitcoin-tx"
            install -Dm755 bin/bitcoin-util "$out/bin/bitcoin-util"
            install -Dm755 bin/bitcoin-wallet "$out/bin/bitcoin-wallet"
            cp -R share "$out/"
            runHook postInstall
          '';
        };

      mkBlockstreamElectrs = pkgs:
        pkgs.rustPlatform.buildRustPackage {
          pname = "blockstream-electrs";
          version = "0.4.1-new-index";
          src = blockstreamElectrsSrc;

          cargoLock = {
            lockFile = "${blockstreamElectrsSrc}/Cargo.lock";
            outputHashes = {
              "electrum-client-0.8.0" = "sha256-HDRdGS7CwWsPXkA1HdurwrVu4lhEx0Ay8vHi08urjZ0=";
              "electrumd-0.1.0" = "sha256-Js4gc/XvokWpPGQGPnWcak2Bt6DNQcosT3CkY841z2c=";
              "jsonrpc-0.12.0" = "sha256-lSNkkQttb8LnJej4Vfe7MrjiNPOuJ5A6w5iLstl9O1k=";
            };
          };

          cargoBuildFlags = [ "--bin" "electrs" ];
          nativeBuildInputs = [
            pkgs.clang
            pkgs.llvmPackages.libclang
            pkgs.pkg-config
          ];

          LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
          BITCOIND_SKIP_DOWNLOAD = true;
          ELECTRUMD_SKIP_DOWNLOAD = true;
          ELEMENTSD_SKIP_DOWNLOAD = true;
          ROCKSDB_INCLUDE_DIR = "${pkgs.rocksdb}/include";
          ROCKSDB_LIB_DIR = "${pkgs.rocksdb}/lib";

          doCheck = false;
        };

      mkRawBinary = pkgs: { pname, version, url, hash, binaryName ? pname }:
        pkgs.stdenvNoCC.mkDerivation {
          inherit pname version;
          src = pkgs.fetchurl { inherit url hash; };
          dontUnpack = true;
          dontConfigure = true;
          dontBuild = true;
          nativeBuildInputs = [ pkgs.autoPatchelfHook ];
          buildInputs = [ pkgs.stdenv.cc.cc.lib ];
          installPhase = ''
            runHook preInstall
            install -Dm755 "$src" "$out/bin/${binaryName}"
            runHook postInstall
          '';
        };

      mkArkdSuite = pkgs:
        let
          version = "0.9.6";
          arch = linuxArch pkgs;
          hashes = {
            ark = {
              amd64 = "sha256-uhMuGQm+MHOg+MjRo8k/rkYlFo8w/FL1OtCtSIqt534=";
              arm64 = "sha256-uT4+YFXrtHYQXL3bhWc30RX5RpQLpCyK1Mci9nxIm88=";
            };
            arkd = {
              amd64 = "sha256-YmSkrhOyfIu4ZBes10AkNfPbNtmxMjfgf9SFuNRLJHY=";
              arm64 = "sha256-Aqdw6lTVv9sH6k+10qRUkrOHpomycZ0fNYan/EeIluE=";
            };
            arkd-wallet = {
              amd64 = "sha256-bxOQifS1QEOnc0HkLARAXX2/CxoWXGwnq2h+r5PWqtk=";
              arm64 = "sha256-sOQDSpdzzjPoRuhqj39RBTFg9g4gxt4SLD4roOyUgkg=";
            };
          };
          bin = name: mkRawBinary pkgs {
            pname = name;
            inherit version;
            url = "https://github.com/arkade-os/arkd/releases/download/v${version}/${name}-linux-${arch}";
            hash = hashes.${name}.${arch};
          };
        in
        pkgs.symlinkJoin {
          name = "arkd-suite-${version}";
          paths = [
            (bin "ark")
            (bin "arkd")
            (bin "arkd-wallet")
          ];
        };

      mkMutinynetCli = pkgs:
        let
          version = "0.1.3";
          arch =
            if pkgs.stdenv.hostPlatform.system == "x86_64-linux" then "x86_64-unknown-linux-gnu"
            else if pkgs.stdenv.hostPlatform.system == "aarch64-linux" then "aarch64-unknown-linux-gnu"
            else throw "unsupported system ${pkgs.stdenv.hostPlatform.system}";
          hashes = {
            x86_64-unknown-linux-gnu = "sha256-28l0kJVlMcF1EpfR+yLspRam85do8yD5FLOv0GPaulY=";
            aarch64-unknown-linux-gnu = "sha256-Axxz+2T3m8k+SeBly9eqkftOWdOmZGAmfjT4jabuhyY=";
          };
        in
        pkgs.stdenvNoCC.mkDerivation {
          pname = "mutinynet-cli";
          inherit version;
          src = pkgs.fetchurl {
            url = "https://github.com/benthecarman/mutinynet-cli/releases/download/v${version}/mutinynet-cli-${arch}.tar.gz";
            hash = hashes.${arch};
          };
          sourceRoot = ".";
          nativeBuildInputs = [ pkgs.autoPatchelfHook ];
          buildInputs = [ pkgs.stdenv.cc.cc.lib ];
          installPhase = ''
            runHook preInstall
            mkdir -p "$out/bin"
            bin="$(find . -type f -name mutinynet-cli | head -n 1)"
            if [ -z "$bin" ]; then
              echo "mutinynet-cli binary not found in release archive" >&2
              exit 1
            fi
            install -m 0755 "$bin" "$out/bin/mutinynet-cli"
            runHook postInstall
          '';
        };

      mkRgbProxyServer = pkgs:
        pkgs.buildNpmPackage rec {
          pname = "rgb-proxy-server";
          version = "0.3.0";

          src = pkgs.fetchFromGitHub {
            owner = "RGB-Tools";
            repo = "rgb-proxy-server";
            rev = version;
            hash = "sha256-hloX/D266h1VDgclz7LoUnZPEwOJJJZ8tAhJzjAYlMg=";
          };

          npmDepsHash = "sha256-TfahXbfZKIPz8Z0qpyeTXbyLVC9/zhnnnu2taszAWH0=";

          nativeBuildInputs = [
            pkgs.makeWrapper
            pkgs.pkg-config
            pkgs.python3
          ];
          buildInputs = [ pkgs.sqlite ];
          dontNpmPrune = true;

          postInstall = ''
            cp -R dist "$out/lib/node_modules/${pname}/dist"
            makeWrapper ${pkgs.nodejs}/bin/node $out/bin/rgb-proxy-server \
              --add-flags "$out/lib/node_modules/${pname}/dist/server.js"
          '';
        };

      mkArkLndSwapProvider = pkgs:
        pkgs.rustPlatform.buildRustPackage {
          pname = "ark-lnd-swap-provider";
          version = "0.1.0";
          src = ./providers/ark-lnd-swap-provider;
          cargoLock = {
            lockFile = ./providers/ark-lnd-swap-provider/Cargo.lock;
            outputHashes = {
              "voltage-tonic-lnd-0.4.0" = "sha256-ZYA5jE7wE84avEEE7QgHucag8t5lGli5sSiQYE47Scg=";
            };
          };
          nativeBuildInputs = [
            pkgs.pkg-config
            pkgs.protobuf
          ];
          buildInputs = [
            pkgs.openssl
            pkgs.sqlite
          ];
          doCheck = false;
        };

      mkBridgeUi = pkgs:
        pkgs.rustPlatform.buildRustPackage {
          pname = "mutinynet-bridge-ui";
          version = "0.1.0";
          src = ./tools/bridge-ui;
          cargoLock.lockFile = ./tools/bridge-ui/Cargo.lock;
          doCheck = false;
        };

      runtimePackages = pkgs: [
        pkgs.awscli2
        pkgs.bash
        pkgs.bc
        pkgs.cacert
        pkgs.coreutils
        pkgs.curl
        pkgs.expect
        pkgs.gh
        pkgs.git
        pkgs.jq
        pkgs.kubectl
        (mkBlockstreamElectrs pkgs)
        (mkMutinynetBitcoin pkgs)
        (mkMutinynetLnd pkgs)
        pkgs.nbxplorer
        pkgs.openssl
        pkgs.postgresql_16
        pkgs.procps
        pkgs.python3
        (mkBridgeUi pkgs)
        (mkArkLndSwapProvider pkgs)
        (mkArkdSuite pkgs)
        (mkMutinynetCli pkgs)
        (mkRgbProxyServer pkgs)
      ];

      mkApp = pkgs: name: script:
        let
          app = pkgs.writeShellApplication {
            name = "mutiny-sim-${name}";
            runtimeInputs = runtimePackages pkgs;
            text = ''
              sim_dir="''${MUTINY_SIM_DIR:-}"
              if [ -z "$sim_dir" ]; then
                if [ -x "$PWD/scripts/${script}" ]; then
                  sim_dir="$PWD"
                else
                  echo "Set MUTINY_SIM_DIR or run from the mutinynet-simulation repo root" >&2
                  exit 2
                fi
              fi
              export MUTINY_SIM_DIR="$sim_dir"
              exec "$sim_dir/scripts/${script}" "$@"
            '';
          };
        in
        {
          type = "app";
          program = "${app}/bin/mutiny-sim-${name}";
          meta.description = "Run mutinynet-simulation ${name}";
        };
    in
    {
      packages = forAllSystems (pkgs: rec {
        arkd-suite = mkArkdSuite pkgs;
        ark-lnd-swap-provider = mkArkLndSwapProvider pkgs;
        bridge-ui = mkBridgeUi pkgs;
        bitcoin-mutinynet = mkMutinynetBitcoin pkgs;
        blockstream-electrs = mkBlockstreamElectrs pkgs;
        lnd = mkMutinynetLnd pkgs;
        mutinynet-cli = mkMutinynetCli pkgs;
        rgb-proxy-server = mkRgbProxyServer pkgs;
        default = arkd-suite;
      });

      formatter = forAllSystems (pkgs: pkgs.nixpkgs-fmt);

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = runtimePackages pkgs ++ [
            pkgs.bashInteractive
            pkgs.cargo
            pkgs.cmake
            pkgs.pkg-config
            pkgs.rustc
            pkgs.sccache
            pkgs.sqlite
            pkgs.tmux
          ];

          shellHook = ''
            export PKG_CONFIG_PATH="${pkgs.openssl.dev}/lib/pkgconfig:${pkgs.sqlite.dev}/lib/pkgconfig:''${PKG_CONFIG_PATH:-}"
            if [ -f ./alias.sh ]; then
              source ./alias.sh
            fi
            echo "Mutinynet simulation aliases loaded: sim-init-local, sim-start, sim-init-unlock, sim-status, sim-setup-bridge-assets, sim-bridge-ui, provider"
          '';
        };
      });

      apps = forAllSystems (pkgs: {
        default = mkApp pkgs "status" "status.sh";
        build-rln = mkApp pkgs "build-rln" "build-rln.sh";
        start = mkApp pkgs "start" "start.sh";
        stop = mkApp pkgs "stop" "stop.sh";
        init-local = mkApp pkgs "init-local" "init-local.sh";
        init-unlock = mkApp pkgs "init-unlock" "init-unlock.sh";
        status = mkApp pkgs "status" "status.sh";
        faucet-auth = mkApp pkgs "faucet-auth" "faucet-auth.sh";
        faucet-fund = mkApp pkgs "faucet-fund" "faucet-fund.sh";
        bitcoind-p2p-tunnel = mkApp pkgs "bitcoind-p2p-tunnel" "bitcoind-p2p-tunnel.sh";
        bitcoind-p2p-port-forward = mkApp pkgs "bitcoind-p2p-port-forward" "bitcoind-p2p-port-forward.sh";
        bridge-ui = mkApp pkgs "bridge-ui" "bridge-ui.sh";
        bridge-plan = mkApp pkgs "bridge-plan" "bridge-plan.sh";
        setup-bridge-assets = mkApp pkgs "setup-bridge-assets" "setup-bridge-assets.sh";
        setup-market-maker = mkApp pkgs "setup-market-maker" "setup-market-maker.sh";
        test-lightning-ark-bridge = mkApp pkgs "test-lightning-ark-bridge" "test-lightning-ark-bridge.sh";
        rgb-asset-to-ark-asset = mkApp pkgs "rgb-asset-to-ark-asset" "rgb-asset-to-ark-asset.sh";
        ark-asset-to-rgb-asset = mkApp pkgs "ark-asset-to-rgb-asset" "ark-asset-to-rgb-asset.sh";
      });
    };
}
