{
  lib,
  dlib,
  dream2nixInterface,
  pkgs,
  callPackageDream,
  utils,
  framework,
  ...
}: let
  l = lib // builtins;
in rec {
  generatePackagesFromLocksTree = {
    source ? throw "pass source",
    tree ? dlib.prepareSourceTree {inherit source;},
    settings ? [],
    inject ? {},
    packageOverrides ? {},
    sourceOverrides ? {},
  }: let
    findDreamLocks = tree:
      (
        let
          dreamLockFile = tree.files."dream-lock.json" or {};
        in
          l.optional
          (
            dreamLockFile
            ? content
            && l.stringLength dreamLockFile.content > 0
          )
          dreamLockFile.jsonContent
      )
      ++ (
        l.flatten (
          l.map findDreamLocks
          (l.attrValues tree.directories)
        )
      );
    dreamLocks = findDreamLocks tree;
    makePackagesForDreamLock = dreamLock:
      (dream2nixInterface.makeOutputsForDreamLock {
        inherit
          dreamLock
          inject
          packageOverrides
          sourceOverrides
          ;
      })
      .packages;
  in
    l.foldl'
    (acc: el: acc // el)
    {}
    (l.map makePackagesForDreamLock dreamLocks);
  makeOutputsForIndexes = {
    source,
    indexes,
    settings ? [],
    inject ? {},
    packageOverrides ? {},
    sourceOverrides ? {},
  }: let
    l = lib // builtins;
    indexNames = l.map (index: index.name) indexes;

    mkApp = script: {
      type = "app";
      program = toString script;
    };

    mkIndexApp = name: input: let
      input' = l.removeAttrs input ["indexer"];
      inputFinal = {outputFile = "${name}/index.json";} // input';
      script = pkgs.writers.writeBash "index" ''
        set -e
        inputJson="$(${pkgs.coreutils}/bin/mktemp)"
        echo '${l.toJSON inputFinal}' > $inputJson
        mkdir -p $(dirname ${inputFinal.outputFile})
        ${framework.apps.index}/bin/index ${input.indexer} $inputJson
      '';
    in
      mkApp script;

    mkTranslateApp = name:
      mkApp (
        pkgs.writers.writeBash "translate-${name}" ''
          set -e
          ${framework.apps.translate-index}/bin/translate-index \
            ${name}/index.json ${name}/locks
        ''
      );

    mkCiAppWith = branchname: commands:
      mkApp (
        utils.writePureShellScript
        (with pkgs; [
          coreutils
          git
          gnugrep
          openssh
        ])
        ''
          set -e
          rm -rf /tmp/.flake
          mkdir -p /tmp/.flake
          cp -r ./* /tmp/.flake
          set -x
          git fetch origin ${branchname} || :
          git checkout -f origin/${branchname} || :
          git branch -D ${branchname} || :
          git checkout -b ${branchname}
          # the flake should always be the one from the current main branch
          rm -rf ./*
          cp -r /tmp/.flake/. ./
          ${commands}
          git add .
          git commit -m "automatic update - $(date --rfc-3339=seconds)"
        ''
      );

    mkCiJobApp = name: input:
      mkCiAppWith
      name
      ''
        ${(mkIndexApp name input).program}
        ${(mkTranslateApp name).program}
      '';

    translateApps = l.listToAttrs (
      l.map
      (
        name:
          l.nameValuePair
          "translate-${name}"
          (mkTranslateApp name)
      )
      indexNames
    );

    indexApps = l.listToAttrs (
      l.map
      (
        input:
          l.nameValuePair
          "index-${input.name}"
          (mkIndexApp input.name input)
      )
      indexes
    );

    ciJobApps = l.listToAttrs (
      l.map
      (
        input:
          l.nameValuePair
          "ci-job-${input.name}"
          (mkCiJobApp input.name input)
      )
      indexes
    );

    ciJobAllApp =
      mkCiAppWith
      "pkgs-all"
      ''
        ${lib.concatStringsSep "\n" (l.mapAttrsToList (_: app: app.program) indexApps)}
        ${lib.concatStringsSep "\n" (l.mapAttrsToList (_: app: app.program) translateApps)}
      '';

    buildAllApp = let
      buildScript =
        pkgs.writers.writePython3 "build-script" {}
        ./build-script.py;
      statsScript =
        pkgs.writers.writePython3 "make-stats" {}
        ./make-stats.py;
    in
      mkApp (
        utils.writePureShellScript
        (with pkgs; [
          coreutils
          git
          parallel
          nix
          nix-eval-jobs
        ])
        ''
          rm -rf ./errors
          mkdir -p ./errors
          JOBS=''${JOBS:-$(nproc)}
          EVAL_JOBS=''${EVAL_JOBS:-1}
          LIMIT=''${LIMIT:-0}
          if [ "$LIMIT" -gt "0" ]; then
            limit="head -n $LIMIT"
          else
            limit="cat"
          fi
          echo "settings: JOBS $JOBS; EVAL_JOBS: $EVAL_JOBS; LIMIT $LIMIT"
          parallel --halt now,fail=1 -j$JOBS --link \
            -a <(nix-eval-jobs --gc-roots-dir $TMPDIR/gcroot --flake "$(realpath .)#packages.x86_64-linux" --workers $EVAL_JOBS --max-memory-size 3000 | $limit) \
            ${buildScript}
          ${statsScript}
          rm -r ./errors
        ''
      );

    mkIndexOutputs = name: let
      src = "${toString source}/${name}/locks";
    in
      if l.pathExists src
      then
        l.removeAttrs
        (generatePackagesFromLocksTree {
          source = src;
          inherit
            settings
            inject
            packageOverrides
            sourceOverrides
            ;
        })
        ["default"]
      else {};

    allPackages =
      l.foldl'
      (acc: el: acc // el)
      {}
      (l.map mkIndexOutputs indexNames);

    outputs = {
      packages = allPackages;
      apps =
        {ci-job-all = ciJobAllApp;}
        // {build-all = buildAllApp;}
        // indexApps
        // translateApps
        // ciJobApps;
    };
  in
    outputs;
}
