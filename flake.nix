{
  description = "Read-only Emacs major modes for inspecting network addresses";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      # One nixpkgs closure, no duplicates.
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Databases.  Pinned as plain files, so `nix flake update' refreshes
    # them and flake.lock holds the hash.  None of them is vendored in
    # the repository.
    asMetadata = {
      url = "https://raw.githubusercontent.com/ipverse/as-metadata/master/as.json";
      type = "file";
      flake = false;
    };
    geoipV4 = {
      url = "https://github.com/sapics/ip-location-db/releases/download/latest/user-country-ipv4.csv";
      type = "file";
      flake = false;
    };
    geoipV6 = {
      url = "https://github.com/sapics/ip-location-db/releases/download/latest/user-country-ipv6.csv";
      type = "file";
      flake = false;
    };
    # IEEE MAC address registries.  The five files split the vendor
    # data by assignment size, and each row names its registry.
    ieeeCid = {
      url = "https://standards-oui.ieee.org/cid/cid.csv";
      type = "file";
      flake = false;
    };
    ieeeIab = {
      url = "https://standards-oui.ieee.org/iab/iab.csv";
      type = "file";
      flake = false;
    };
    ieeeMam = {
      url = "https://standards-oui.ieee.org/oui28/mam.csv";
      type = "file";
      flake = false;
    };
    ieeeOui = {
      url = "https://standards-oui.ieee.org/oui/oui.csv";
      type = "file";
      flake = false;
    };
    ieeeOui36 = {
      url = "https://standards-oui.ieee.org/oui36/oui36.csv";
      type = "file";
      flake = false;
    };
    ianaAsn16 = {
      url = "https://www.iana.org/assignments/as-numbers/as-numbers-1.csv";
      type = "file";
      flake = false;
    };
    ianaAsn32 = {
      url = "https://www.iana.org/assignments/as-numbers/as-numbers-2.csv";
      type = "file";
      flake = false;
    };
    ianaIpv4 = {
      url = "https://www.iana.org/assignments/iana-ipv4-special-registry/iana-ipv4-special-registry-1.csv";
      type = "file";
      flake = false;
    };
    ianaIpv6 = {
      url = "https://www.iana.org/assignments/iana-ipv6-special-registry/iana-ipv6-special-registry-1.csv";
      type = "file";
      flake = false;
    };
    ianaServices = {
      url = "https://www.iana.org/assignments/service-names-port-numbers/service-names-port-numbers.csv";
      type = "file";
      flake = false;
    };
  };

  outputs =
    inputs@{
      flake-parts,
      treefmt-nix,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ treefmt-nix.flakeModule ];

      # Elisp is architecture independent, so evaluate on both Linux
      # targets from the start.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        {
          pkgs,
          lib,
          config,
          ...
        }:
        let
          # One data package: symlink every pinned database under a
          # single directory.  Large files already live in the store, so
          # a symlink avoids copying the 70 MB AS metadata file.
          networkModesData =
            pkgs.runCommand "network-modes-data"
              {
                meta.description = "Pinned network databases for the Emacs network modes";
              }
              ''
                mkdir -p $out
                ln -s ${inputs.asMetadata} $out/as.json
                ln -s ${inputs.geoipV4} $out/user-country-ipv4.csv
                ln -s ${inputs.geoipV6} $out/user-country-ipv6.csv
                ln -s ${inputs.ianaAsn16} $out/as-numbers-1.csv
                ln -s ${inputs.ianaAsn32} $out/as-numbers-2.csv
                ln -s ${inputs.ianaIpv4} $out/iana-ipv4-special-registry.csv
                ln -s ${inputs.ianaIpv6} $out/iana-ipv6-special-registry.csv
                ln -s ${inputs.ianaServices} $out/service-names-port-numbers.csv
                ln -s ${inputs.ieeeOui} $out/oui.csv
                ln -s ${inputs.ieeeMam} $out/mam.csv
                ln -s ${inputs.ieeeOui36} $out/oui36.csv
                ln -s ${inputs.ieeeIab} $out/iab.csv
                ln -s ${inputs.ieeeCid} $out/cid.csv
                # The PSL comes from nixpkgs, which tracks publicsuffix.org.
                ln -s ${pkgs.publicsuffix-list}/share/publicsuffix/public_suffix_list.dat \
                  $out/public_suffix_list.dat
              '';

          # Date of the flake source, folded into the version string.
          # A fresh repository without commits falls back to the epoch,
          # which keeps Nix versions parseable.
          lastModifiedDate = inputs.self.lastModifiedDate or "19700101000000";
          version =
            "0.1.0-unstable-${builtins.substring 0 4 lastModifiedDate}"
            + "-${builtins.substring 4 2 lastModifiedDate}"
            + "-${builtins.substring 6 2 lastModifiedDate}";

          # The package stays overridable, so a consumer can swap the
          # Emacs, its package set, the build function, the evil package
          # or the database derivation:
          #   inputs.network-modes.packages.${system}.default.override {
          #     emacs = pkgs.emacs-nox;
          #   }
          # The flake passes the commit-derived version, because a plain
          # import of the expression cannot know it.
          networkModes = lib.makeOverridable (
            {
              # One Emacs package set supplies every dependency, so an
              # override of this argument moves all of them.
              emacs ? pkgs.emacs,
              emacsPackages ? emacs.pkgs,
              melpaBuild ? emacsPackages.melpaBuild,
              version ? "0.1.0",
              # Evil reaches the build Emacs only.  net-evil.el needs the
              # library to byte-compile, and the ERT suite tests its key
              # bindings, so the build cannot drop it.  The package
              # metadata still names no dependency.
              evil ? emacs.pkgs.evil,
              data ? networkModesData,
            }:
            melpaBuild {
              pname = "network-modes";
              inherit version;

              src = lib.cleanSource ./.;

              # One substitution replaces every database option with a
              # single stable prefix, so the Elisp defaults stay readable
              # in the repository.
              postPatch = ''
                substituteInPlace net-mode.el \
                  --replace-fail '(defcustom net-data-directory nil' \
                    '(defcustom net-data-directory "${data}"'
              '';

              # Warnings become errors: the cheapest lint the package gets.
              turnCompilationWarningToError = true;

              # The default installPhase compiles the packaged files with
              # `-Q', so preInstall puts the evil elisp directory on
              # EMACSLOADPATH for that compile.  Do not add evil to
              # packageRequires: the dependency is optional for users of
              # the package.
              preInstall = ''
                evil_dir=$(find ${evil}/share/emacs/site-lisp/elpa \
                  -mindepth 1 -maxdepth 1 -type d -name 'evil-*' -print -quit)
                export EMACSLOADPATH="$evil_dir:''${EMACSLOADPATH-}"
              '';

              # The ERT suite needs no external Elisp dependencies except
              # evil, which net-evil-tests.el skips without.  The check
              # phase supplies the evil elisp directory, so the optional
              # layer is compiled and tested while the package stays free
              # of the dependency.
              doCheck = true;
              checkPhase = ''
                runHook preCheck
                evil_load_path=$(find ${evil}/share/emacs/site-lisp/elpa \
                  -mindepth 1 -maxdepth 1 -type d -name 'evil-*' -print -quit)
                emacs --batch -L . -L "$evil_load_path" \
                  -l net-tests.el -l net-evil-tests.el \
                  -f ert-run-tests-batch-and-exit
                runHook postCheck
              '';

              meta = {
                description = "Read-only Emacs major modes for inspecting network addresses";
                longDescription = ''
                  A set of major modes that display details about network
                  addresses: IPv4 and IPv6 addresses, CIDR prefixes, MAC
                  addresses, autonomous system numbers, domain names and
                  AF_VSOCK addresses.

                  Every mode derives from `special-mode', so the buffers stay
                  read-only.  Fields are copyable buttons and related
                  addresses open their own inspect buffer.  One command,
                  `net-inspect', sniffs the token at point and picks the
                  right mode.

                  The modes read pinned offline databases: the IANA
                  special-purpose address registries, the IANA AS number and
                  service name registries, the Public Suffix List, the
                  ipverse as-metadata JSON file, PDDL country range files and
                  the five IEEE MAC address registries.  Wireshark's manuf
                  file is an optional MAC vendor source.

                  RDAP lookups come from a buffer button or the `b' key and
                  only run when invoked.  Opening a buffer never contacts the
                  network.
                '';
                license = lib.licenses.agpl3Plus;
                homepage = "https://github.com/nagy/emacs-network-modes";
                maintainers = with lib.maintainers; [ nagy ];
                platforms = lib.platforms.unix;
              };
            }
          ) { inherit version; };

          # Sources without the test suite, used by the two lint gates.
          lintFiles = ''
            export HOME=$TMPDIR
            mode_files=()
            for file in "$src"/*.el; do
              case "$file" in
                *-tests.el) continue ;;
              esac
              cp "$file" .
              mode_files+=("$(basename "$file")")
            done
          '';
        in
        {
          treefmt = {
            projectRootFile = "flake.nix";
            programs.nixfmt.enable = true;
          };

          packages.network-modes = networkModes;
          packages.default = networkModes;

          # `nix flake check' builds the package too: byte-compilation
          # with warnings as errors plus the full ERT suite gate every
          # change, not only `nix build'.
          checks.package = networkModes;

          # package-lint: ELPA policy (headers, symbol prefixes,
          # dependency declarations).  The package shares the short
          # `net-' prefix across files, so whitelist it.
          checks.package-lint =
            pkgs.runCommandLocal "network-modes-package-lint"
              {
                nativeBuildInputs = [
                  (pkgs.emacsPackages.emacsWithPackages (p: [ p.package-lint ]))
                ];
                src = networkModes.src;
              }
              ''
                ${lintFiles}

                emacs --batch -l package-lint \
                  --eval '(setq package-lint--sane-prefixes (concat package-lint--sane-prefixes "\\|\\`net-"))' \
                  -f package-lint-batch-and-exit \
                  "''${mode_files[@]}"

                touch $out
              '';

          # checkdoc: docstring conventions, which byte-compilation
          # cannot check.  checkdoc exits 0 even on findings, so gate on
          # non-empty output.
          checks.checkdoc =
            pkgs.runCommandLocal "network-modes-checkdoc"
              {
                nativeBuildInputs = [ pkgs.emacs ];
                src = networkModes.src;
              }
              ''
                ${lintFiles}

                lint_log=$(emacs --batch -l checkdoc \
                  --eval '(setq checkdoc-arguments-in-order-flag t)' \
                  --eval "(mapc #'checkdoc-file command-line-args-left)" \
                  "''${mode_files[@]}" 2>&1)
                if [ -n "$lint_log" ]; then printf '%s\n' "$lint_log"; exit 1; fi
                touch $out
              '';

          devShells.default = pkgs.mkShell {
            # Evil comes along for the optional net-evil.el layer.
            packages = [
              (pkgs.emacsPackages.emacsWithPackages (p: [
                p.package-lint
                p.embark
                p.evil
              ]))
              pkgs.nix
            ];
          };
        };
    };
}
