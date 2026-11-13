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
    # IP to AS number ranges.  One file per family, both sorted by
    # start address, so the reader can binary search them.
    iptoasnV4 = {
      url = "https://iptoasn.com/data/ip2asn-v4.tsv.gz";
      type = "file";
      flake = false;
    };
    iptoasnV6 = {
      url = "https://iptoasn.com/data/ip2asn-v6.tsv.gz";
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
          #
          # The four range tables are packed at build time, so the Emacs
          # readers binary search fixed-width rows instead of parsing
          # megabytes of CSV and gunzipping a TSV on first use.  The raw
          # files stay linked for users who want the upstream shape.
          networkModesData =
            pkgs.runCommand "network-modes-data"
              {
                meta.description = "Pinned network databases for the Emacs network modes";
                # The packer loads `net-mode.el', which now needs
                # magit-section for its section tree, so the build Emacs
                # carries that library.
                nativeBuildInputs = [
                  (pkgs.emacs-nox.pkgs.emacsWithPackages (p: [ p.magit-section ]))
                ];
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
                ln -s ${inputs.iptoasnV4} $out/ip2asn-v4.tsv.gz
                ln -s ${inputs.iptoasnV6} $out/ip2asn-v6.tsv.gz
                ln -s ${inputs.ieeeOui} $out/oui.csv
                ln -s ${inputs.ieeeMam} $out/mam.csv
                ln -s ${inputs.ieeeOui36} $out/oui36.csv
                ln -s ${inputs.ieeeIab} $out/iab.csv
                ln -s ${inputs.ieeeCid} $out/cid.csv
                # The PSL comes from nixpkgs, which tracks publicsuffix.org.
                ln -s ${pkgs.publicsuffix-list}/share/publicsuffix/public_suffix_list.dat \
                  $out/public_suffix_list.dat

                # The packer is Emacs Lisp, so one `bindat' description
                # reads and writes the format.  It needs the readers and
                # the address parser, and nothing else.
                cp ${./net-mode.el} net-mode.el
                cp ${./net-geo.el} net-geo.el
                cp ${./net-asn.el} net-asn.el
                cp ${./net-ip.el} net-ip.el
                cp ${./tools/pack-network-data.el} pack-network-data.el
                emacs --batch -L . -l pack-network-data.el -- \
                  --geo-v4 ${inputs.geoipV4} \
                  --geo-v6 ${inputs.geoipV6} \
                  --asn-v4 ${inputs.iptoasnV4} \
                  --asn-v6 ${inputs.iptoasnV6} \
                  --out-dir $out
              '';

          # Emacs loads a language grammar from a file named
          # `libtree-sitter-LANG.so', and nixpkgs installs the parser of
          # a grammar package as `parser'.  The wrapper gives the JSON
          # grammar the name that Emacs reads, so the JSON view can take
          # `json-ts-mode' when the machine carries it.
          jsonGrammar = pkgs.runCommand "tree-sitter-json-emacs" { } ''
            mkdir -p $out
            ln -s ${pkgs.tree-sitter-grammars.tree-sitter-json}/parser \
              $out/libtree-sitter-json.so
            ln -s ${pkgs.tree-sitter-grammars.tree-sitter-json}/queries \
              $out/queries
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
              # The section tree of every inspect buffer comes from
              # magit-section, which the package declares and therefore
              # propagates to its users.
              magit-section ? emacsPackages.magit-section,
              # Evil reaches the build Emacs only.  net-evil.el needs the
              # library to byte-compile, and the ERT suite tests its key
              # bindings, so the build cannot drop it.  The package
              # metadata still names no dependency.
              evil ? emacsPackages.evil,
              data ? networkModesData,
            }:
            let
              # `melpaBuild' keeps `packageRequires' off the load path of
              # its own build, so the build, the install and the check
              # phases run the wrapped Emacs that carries both
              # libraries.
              emacsWithDeps = emacsPackages.emacsWithPackages (_: [
                magit-section
                evil
              ]);
              withDepsPath = ''
                export PATH="${emacsWithDeps}/bin:$PATH"
              '';
            in
            melpaBuild {
              pname = "network-modes";
              inherit version;

              src = lib.cleanSource ./.;

              # The library reaches the user through the package set, so
              # a downstream Emacs finds it without a separate install.
              packageRequires = [ magit-section ];

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

              # The build compiles with the wrapped Emacs, so the
              # libraries that `packageRequires' names and the optional
              # evil layer resolve without an `EMACSLOADPATH' export.
              preBuild = withDepsPath;
              preInstall = withDepsPath;

              # The ERT suite needs magit-section and, for
              # net-evil-test.el, evil on the load path; the wrapped
              # Emacs carries both, so the package stays free of the
              # optional evil dependency.
              doCheck = true;
              checkPhase = ''
                runHook preCheck
                ${withDepsPath}
                # melpaBuild stages root *.el files only, so the test tree
                # comes back from the store before the glob can see it.
                cp -r ${./test} ./test
                # printf repeats "-l %s" once per match, which turns the
                # glob into -l <file> argument pairs.  failglob makes an
                # empty glob a shell error, so the || guard fires even
                # without `set -e'.  A new test file then needs no flake
                # edit, and a broken glob cannot pass zero tests.
                shopt -s failglob
                test_args=$(printf -- "-l %s " test/*-test.el) || {
                  echo 'no tests matched test/*-test.el' >&2
                  exit 1
                }
                shopt -u failglob
                # The JSON view takes its parent mode from the machine,
                # so the suite runs twice: without the JSON grammar,
                # which serves the view through js-json-mode, and with
                # it, which serves the view through json-ts-mode.
                emacs --batch -L . -L test \
                  $test_args -f ert-run-tests-batch-and-exit
                emacs --batch -L . -L test \
                  --eval '(setq treesit-extra-load-path (list "${jsonGrammar}"))' \
                  $test_args -f ert-run-tests-batch-and-exit
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

          # Sources plus the test tree, used by the two lint gates.
          # The test files share the lint rules of the modes, so a
          # docstring defect there fails the same check.
          lintFiles = ''
            mode_files=()
            for file in "$src"/*.el; do
              cp "$file" .
              mode_files+=("$(basename "$file")")
            done
            cp -r "$src"/test .
            test_files=(test/*.el)
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

          # The packed range tables and the Elisp decoders must agree.
          # This check reads the real derivation, not a test fixture.
          checks.data-tables =
            pkgs.runCommandLocal "network-modes-data-tables"
              {
                nativeBuildInputs = [
                  # The readers load `net-mode.el', which needs the
                  # section library to draw a buffer.
                  (pkgs.emacs.pkgs.emacsWithPackages (p: [ p.magit-section ]))
                  # Emacs writes `~/.emacs.d' and tramp caches, so the
                  # builder needs a writable home.  The hook gives each
                  # derivation a private one, so two checks never leak
                  # state into each other.
                  pkgs.writableTmpDirAsHomeHook
                ];
                src = networkModes.src;
              }
              ''
                cp "$src"/*.el .
                emacs --batch -L . \
                  --eval '(setq net-data-directory "${networkModesData}")' \
                  -l network-modes -l net-geo \
                  --eval '(let ((country (net-geo-country (plist-get (net-ip-parse "8.8.8.8") :value) 4))) (unless (equal country "US") (error "GeoIP v4: %S" country)))' \
                  --eval '(let ((entry (net-asn-ip-entry (plist-get (net-ip-parse "8.8.8.8") :value) 4))) (unless (equal (plist-get entry :asn) 15169) (error "ASN v4: %S" entry)))' \
                  --eval '(let ((country (net-geo-country (plist-get (net-ip-parse "2001:4860:4860::8888") :value) 6))) (unless (equal country "US") (error "GeoIP v6: %S" country)))' \
                  --eval '(let ((entry (net-asn-ip-entry (plist-get (net-ip-parse "2001:4860:4860::8888") :value) 6))) (unless (equal (plist-get entry :asn) 15169) (error "ASN v6: %S" entry)))'
                touch $out
              '';

          # package-lint: ELPA policy (headers, symbol prefixes,
          # dependency declarations).  The package shares the short
          # `net-' prefix across files, so whitelist it.  The mode
          # files lint as separate packages, the way they always did,
          # because embark-net.el and ol-net.el keep their own prefixes
          # and their own headers.  The test files lint against the
          # entry library as main file, so package-lint reads them as
          # part of network-modes and not as packages of their own.
          checks.package-lint =
            pkgs.runCommandLocal "network-modes-package-lint"
              {
                nativeBuildInputs = [
                  (pkgs.emacsPackages.emacsWithPackages (p: [
                    p.package-lint
                    # package-lint accepts a declared dependency only
                    # when it can see the library installed.
                    p.magit-section
                  ]))
                  # Private writable home for Emacs, so no check shares
                  # `~/.emacs.d' with another one.
                  pkgs.writableTmpDirAsHomeHook
                ];
                src = networkModes.src;
              }
              ''
                ${lintFiles}

                emacs --batch -l package-lint \
                  --eval '(setq package-lint--sane-prefixes (concat package-lint--sane-prefixes "\\|\\`net-"))' \
                  -f package-lint-batch-and-exit \
                  "''${mode_files[@]}"

                emacs --batch -l package-lint \
                  --eval '(setq package-lint-main-file "network-modes.el")' \
                  --eval '(setq package-lint--sane-prefixes (concat package-lint--sane-prefixes "\\|\\`net-"))' \
                  -f package-lint-batch-and-exit \
                  "''${test_files[@]}"

                touch $out
              '';

          # checkdoc: docstring conventions, which byte-compilation
          # cannot check.  checkdoc exits 0 even on findings, so gate on
          # non-empty output.
          checks.checkdoc =
            pkgs.runCommandLocal "network-modes-checkdoc"
              {
                nativeBuildInputs = [
                  pkgs.emacs
                  # Private writable home for Emacs, so no check shares
                  # `~/.emacs.d' with another one.
                  pkgs.writableTmpDirAsHomeHook
                ];
                src = networkModes.src;
              }
              ''
                ${lintFiles}

                lint_log=$(emacs --batch -l checkdoc \
                  --eval '(setq checkdoc-arguments-in-order-flag t)' \
                  --eval "(mapc #'checkdoc-file command-line-args-left)" \
                  "''${mode_files[@]}" "''${test_files[@]}" 2>&1)
                if [ -n "$lint_log" ]; then printf '%s\n' "$lint_log"; exit 1; fi
                touch $out
              '';

          devShells.default = pkgs.mkShell {
            # Evil comes along for the optional net-evil.el layer, and
            # magit-section for the section tree of every buffer.
            packages = [
              (pkgs.emacsPackages.emacsWithPackages (p: [
                p.package-lint
                p.embark
                p.evil
                p.magit-section
              ]))
              pkgs.nix
              jsonGrammar
            ];
            # Emacs reads a grammar only from `treesit-extra-load-path',
            # and a shell cannot set a Lisp variable.  The variable below
            # names the grammar so a developer can serve the JSON view
            # through `json-ts-mode':
            #
            #   emacs -Q --batch -L . -L test \
            #     --eval "(setq treesit-extra-load-path \
            #                 (list \"$NET_TREESIT_GRAMMAR\"))" \
            #     $(printf -- "-l %s " test/*-test.el) \
            #     -f ert-run-tests-batch-and-exit
            shellHook = ''
              export NET_TREESIT_GRAMMAR=${jsonGrammar}
            '';
          };
        };
    };
}
