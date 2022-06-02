# Logic for generating Buildkite pipelines from Nix build targets read
# by //nix/readTree.
#
# It outputs a "YAML" (actually JSON) file which is evaluated and
# submitted to Buildkite at the start of each build.
#
# The structure of the file that is being created is documented here:
#   https://buildkite.com/docs/pipelines/defining-steps
{ depot, pkgs, ... }:

let
  inherit (builtins)
    attrValues
    concatMap
    concatStringsSep
    filter
    foldl'
    getEnv
    hasAttr
    hashString
    isNull
    isString
    length
    listToAttrs
    mapAttrs
    partition
    pathExists
    toJSON
    unsafeDiscardStringContext;

  inherit (pkgs) lib runCommandNoCC writeText;
  inherit (depot.nix.readTree) mkLabel;
in
rec {
  # Creates a Nix expression that yields the target at the specified
  # location in the repository.
  #
  # This makes a distinction between normal targets (which physically
  # exist in the repository) and subtargets (which are "virtual"
  # targets exposed by a physical one) to make it clear in the build
  # output which is which.
  mkBuildExpr = target:
    let
      descend = expr: attr: "builtins.getAttr \"${attr}\" (${expr})";
      targetExpr = foldl' descend "import ./. {}" target.__readTree;
      subtargetExpr = descend targetExpr target.__subtarget;
    in
    if target ? __subtarget then subtargetExpr else targetExpr;

  # Determine whether to skip a target if it has not diverged from the
  # HEAD branch.
  shouldSkip = parentTargetMap: label: drvPath:
    if (hasAttr label parentTargetMap) && parentTargetMap."${label}".drvPath == drvPath
    then "Target has not changed."
    else false;

  # Create build command for a derivation target.
  mkBuildCommand = target: drvPath: concatStringsSep " " [
    # First try to realise the drvPath of the target so we don't evaluate twice.
    # Nix has no concept of depending on a derivation file without depending on
    # at least one of its `outPath`s, so we need to discard the string context
    # if we don't want to build everything during pipeline construction.
    "(nix-store --realise '${drvPath}' --add-root result --indirect && readlink result)"

    # Since we don't gcroot the derivation files, they may be deleted by the
    # garbage collector. In that case we can reevaluate and build the attribute
    # using nix-build.
    "|| (test ! -f '${drvPath}' && nix-build -E '${mkBuildExpr target}' --show-trace)"
  ];

  # Create a pipeline step from a single target.
  mkStep = headBranch: parentTargetMap: target:
    let
      label = mkLabel target;
      drvPath = unsafeDiscardStringContext target.drvPath;
      shouldSkip' = shouldSkip parentTargetMap;
    in
    {
      label = ":nix: " + label;
      key = hashString "sha1" label;
      skip = shouldSkip' label drvPath;
      command = mkBuildCommand target drvPath;
      env.READTREE_TARGET = label;

      # Add a dependency on the initial static pipeline step which
      # always runs. This allows build steps uploaded in batches to
      # start running before all batches have been uploaded.
      depends_on = ":init:";
    };

  # Helper function to inelegantly divide a list into chunks of at
  # most n elements.
  #
  # This works by assigning each element a chunk ID based on its
  # index, and then grouping all elements by their chunk ID.
  chunksOf = n: list:
    let
      chunkId = idx: toString (idx / n + 1);
      assigned = lib.imap1 (idx: value: { inherit value; chunk = chunkId idx; }) list;
      unchunk = mapAttrs (_: elements: map (e: e.value) elements);
    in
    unchunk (lib.groupBy (e: e.chunk) assigned);

  # Define a build pipeline chunk as a JSON file, using the pipeline
  # format documented on
  # https://buildkite.com/docs/pipelines/defining-steps.
  makePipelineChunk = name: chunkId: chunk: rec {
    filename = "${name}-chunk-${chunkId}.json";
    path = writeText filename (toJSON {
      steps = chunk;
    });
  };

  # Split the pipeline into chunks of at most 192 steps at once, which
  # are uploaded sequentially. This is because of a limitation in the
  # Buildkite backend which struggles to process more than a specific
  # number of chunks at once.
  pipelineChunks = name: steps:
    attrValues (mapAttrs (makePipelineChunk name) (chunksOf 192 steps));

  # Create a pipeline structure for the given targets.
  mkPipeline =
    {
      # HEAD branch of the repository on which release steps, GC
      # anchoring and other "mainline only" steps should run.
      headBranch
    , # List of derivations as read by readTree (in most cases just the
      # output of readTree.gather) that should be built in Buildkite.
      #
      # These are scheduled as the first build steps and run as fast as
      # possible, in order, without any concurrency restrictions.
      drvTargets
    , # Derivation map of a parent commit. Only targets which no longer
      # correspond to the content of this map will be built. Passing an
      # empty map will always build all targets.
      parentTargetMap ? { }
    , # A list of plain Buildkite step structures to run alongside the
      # build for all drvTargets, but before proceeding with any
      # post-build actions such as status reporting.
      #
      # Can be used for things like code formatting checks.
      additionalSteps ? [ ]
    , # A list of plain Buildkite step structures to run after all
      # previous steps succeeded.
      #
      # Can be used for status reporting steps and the like.
      postBuildSteps ? [ ]
    }:
    let
      # Convert a target into all of its build and post-build steps,
      # treated separately as they need to be in different chunks.
      targetToSteps = target:
        let
          step = mkStep headBranch parentTargetMap target;

          # Same step, but with an override function applied. This is
          # used in mkExtraStep if the extra step needs to modify the
          # parent derivation somehow.
          #
          # Note that this will never affect the label.
          overridable = f: mkStep headBranch parentTargetMap (f target);

          # Split build/post-build steps
          splitExtraSteps = partition ({ postStep, ... }: postStep)
            (attrValues (mapAttrs
              (name: value: {
                inherit name value;
                postStep = (value ? prompt) || (value.postBuild or false);
              })
              (target.meta.ci.extraSteps or { })));

          mkExtraStep' = { name, value, ... }: mkExtraStep overridable name value;
          extraBuildSteps = map mkExtraStep' splitExtraSteps.wrong; # 'wrong' -> no prompt
          extraPostSteps = map mkExtraStep' splitExtraSteps.right; # 'right' -> has prompt
        in
        {
          buildSteps = [ step ] ++ extraBuildSteps;
          postSteps = extraPostSteps;
        };

      # Combine all target steps into separate build and post-build step lists.
      steps = foldl'
        (acc: t: {
          buildSteps = acc.buildSteps ++ t.buildSteps;
          postSteps = acc.postSteps ++ t.postSteps;
        })
        { buildSteps = [ ]; postSteps = [ ]; }
        (map targetToSteps drvTargets);

      buildSteps =
        # Add build steps for each derivation target and their extra
        # steps.
        steps.buildSteps

        # Add additional steps (if set).
        ++ additionalSteps;

      postSteps =
        # Add post-build steps for each derivation target.
        steps.postSteps

        # Add any globally defined post-build steps.
        ++ postBuildSteps;

      buildChunks = pipelineChunks "build" buildSteps;
      postBuildChunks = pipelineChunks "post" postSteps;
      chunks = buildChunks ++ postBuildChunks;
    in
    runCommandNoCC "buildkite-pipeline" { } ''
      mkdir $out
      echo "Generated ${toString (length chunks)} pipeline chunks"
      ${
        lib.concatMapStringsSep "\n"
          (chunk: "cp ${chunk.path} $out/${chunk.filename}") chunks
      }
    '';

  # Create a drvmap structure for the given targets, containing the
  # mapping of all target paths to their derivations. The mapping can
  # be persisted for future use.
  mkDrvmap = drvTargets: writeText "drvmap.json" (toJSON (listToAttrs (map
    (target: {
      name = mkLabel target;
      value = {
        drvPath = unsafeDiscardStringContext target.drvPath;

        # Include the attrPath in the output to reconstruct the drv
        # without parsing the human-readable label.
        attrPath = target.__readTree ++ lib.optionals (target ? __subtarget) [
          target.__subtarget
        ];
      };
    })
    drvTargets)));

  # Implementation of extra step logic.
  #
  # Each target extra step is an attribute specified in
  # `meta.ci.extraSteps`. Its attribute name will be used as the step
  # name on Buildkite.
  #
  #   command (required): A command that will be run in the depot
  #     checkout when this step is executed. Should be a derivation
  #     resulting in a single executable file, e.g. through
  #     pkgs.writeShellScript.
  #
  #   label (optional): Human-readable label for this step to display
  #     in the Buildkite UI instead of the attribute name.
  #
  #   prompt (optional): Setting this blocks the step until confirmed
  #     by a human. Should be a string which is displayed for
  #     confirmation. These steps always run after the main build is
  #     done and have no influence on CI status.
  #
  #   postBuild (optional): If set to true, this step will run after
  #     all primary build steps (that is, after status has been reported
  #     back to CI).
  #
  #   needsOutput (optional): If set to true, the parent derivation
  #     will be built in the working directory before running the
  #     command. Output will be available as 'result'.
  #     TODO: Figure out multiple-output derivations.
  #
  #   parentOverride (optional): A function (drv -> drv) to override
  #     the parent's target definition when preparing its output. Only
  #     used in extra steps that use needsOutput.
  #
  #   branches (optional): Git references (branches, tags ... ) on
  #     which this step should be allowed to run. List of strings.
  #
  #   alwaysRun (optional): If set to true, this step will always run,
  #     even if its parent has not been rebuilt.
  #
  # Note that gated steps are independent of each other.

  # Create a gated step in a step group, independent from any other
  # steps.
  mkGatedStep = { step, label, parent, prompt }: {
    inherit (step) depends_on;
    group = label;
    skip = parent.skip or false;

    steps = [
      {
        inherit (step) branches;
        inherit prompt;
        block = ":radio_button: Run ${label}? (from ${parent.env.READTREE_TARGET})";
      }

      # The explicit depends_on of the wrapped step must be removed,
      # otherwise its dependency relationship with the gate step will
      # break.
      (builtins.removeAttrs step [ "depends_on" ])
    ];
  };

  # Create the Buildkite configuration for an extra step, optionally
  # wrapping it in a gate group.
  mkExtraStep = overridableParent: key:
    { command
    , label ? key
    , prompt ? false
    , needsOutput ? false
    , parentOverride ? (x: x)
    , branches ? null
    , alwaysRun ? false
    , postBuild ? false
    }@cfg:
    let
      parent = overridableParent parentOverride;
      parentLabel = parent.env.READTREE_TARGET;

      step = {
        label = ":gear: ${label} (from ${parentLabel})";
        skip = if alwaysRun then false else parent.skip or false;
        depends_on = lib.optional (!alwaysRun && !needsOutput) parent.key;
        branches = if branches != null then lib.concatStringsSep " " branches else null;

        command = pkgs.writeShellScript "${key}-script" ''
          set -ueo pipefail
          ${lib.optionalString needsOutput "echo '~~~ Preparing build output of ${parentLabel}'"}
          ${lib.optionalString needsOutput parent.command}
          echo '+++ Running extra step command'
          exec ${command}
        '';
      };
    in
    if (isString prompt)
    then
      mkGatedStep
        {
          inherit step label parent prompt;
        }
    else step;
}
