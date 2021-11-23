# Copyright (c) 2019 Vincent Ambo
# Copyright (c) 2020-2021 The TVL Authors
# SPDX-License-Identifier: MIT
#
# Provides a function to automatically read a a filesystem structure
# into a Nix attribute set.
#
# Called with an attribute set taking the following arguments:
#
#   path: Path to a directory from which to start reading the tree.
#
#   args: Argument set to pass to each imported file.
#
#   filter: Function to filter `args` based on the tree location. This should
#           be a function of the form `args -> location -> args`, where the
#           location is a list of strings representing the path components of
#           the current readTree target. Optional.
{ ... }:

let
  inherit (builtins)
    attrNames
    concatStringsSep
    elem
    elemAt
    filter
    hasAttr
    head
    isAttrs
    listToAttrs
    map
    match
    readDir
    substring;

  argsWithPath = args: parts:
    let meta.locatedAt = parts;
    in meta // (if isAttrs args then args else args meta);

  readDirVisible = path:
    let
      children = readDir path;
      isVisible = f: f == ".skip-subtree" || (substring 0 1 f) != ".";
      names = filter isVisible (attrNames children);
    in listToAttrs (map (name: {
      inherit name;
      value = children.${name};
    }) names);

  # Create a mark containing the location of this attribute and
  # a list of all child attribute names added by readTree.
  marker = parts: children: {
    __readTree = parts;
    __readTreeChildren = builtins.attrNames children;
  };

  # Import a file and enforce our calling convention
  importFile = args: scopedArgs: path: parts: filter:
  let
      importedFile = if scopedArgs != {}
                     then builtins.scopedImport scopedArgs path
                     else import path;
      pathType = builtins.typeOf importedFile;
  in
    if pathType != "lambda"
    then builtins.throw "readTree: trying to import ${toString path}, but it’s a ${pathType}, you need to make it a function like { depot, pkgs, ... }"
    else importedFile (filter parts (argsWithPath args parts));

  nixFileName = file:
    let res = match "(.*)\\.nix" file;
    in if res == null then null else head res;

  readTree = { args, initPath, rootDir, parts, argsFilter, scopedArgs }:
    let
      dir = readDirVisible initPath;
      joinChild = c: initPath + ("/" + c);

      self = if rootDir
        then { __readTree = []; }
        else importFile args scopedArgs initPath parts argsFilter;

      # Import subdirectories of the current one, unless the special
      # `.skip-subtree` file exists which makes readTree ignore the
      # children.
      #
      # This file can optionally contain information on why the tree
      # should be ignored, but its content is not inspected by
      # readTree
      filterDir = f: dir."${f}" == "directory";
      children = if hasAttr ".skip-subtree" dir then [] else map (c: {
        name = c;
        value = readTree {
          inherit argsFilter scopedArgs;
          args = args;
          initPath = (joinChild c);
          rootDir = false;
          parts = (parts ++ [ c ]);
        };
      }) (filter filterDir (attrNames dir));

      # Import Nix files
      nixFiles = filter (f: f != null) (map nixFileName (attrNames dir));
      nixChildren = map (c: let
        p = joinChild (c + ".nix");
        childParts = parts ++ [ c ];
        imported = importFile args scopedArgs p childParts argsFilter;
      in {
        name = c;
        value =
          if isAttrs imported
          then imported // marker childParts {}
          else imported;
      }) nixFiles;

      nodeValue = if dir ? "default.nix" then self else {};

      allChildren = listToAttrs (
        if dir ? "default.nix"
        then children
        else nixChildren ++ children
      );

    in
      if isAttrs nodeValue
      then nodeValue // allChildren // (marker parts allChildren)
      else nodeValue;

in {
  __functor = _:
    { path
    , args
    , filter ? (_parts: x: x)
    , scopedArgs ? {} }:
      readTree {
        inherit args scopedArgs;
        argsFilter = filter;
        initPath = path;
        rootDir = true;
        parts = [];
      };

  # In addition to readTree itself, some functionality is exposed that
  # is useful for users of readTree.

  # Create a readTree filter disallowing access to the specified
  # top-level folder in the repository, except for specific exceptions
  # specified by their (full) paths.
  #
  # Called with the arguments:
  #
  #   folder: Name of the restricted top-level folder (e.g. 'experimental')
  #
  #   exceptions: List of readTree parts (e.g. [ [ "services" "some-app" ] ]),
  #               which should be able to access the restricted folder.
  #
  #   reason: Textual explanation for the restriction (included in errors)
  restrictFolder = { folder, exceptions ? [], reason }: parts: args:
    if (elemAt parts 0) == folder || elem parts exceptions
    then args
    else args // {
      depot = args.depot // {
        "${folder}" = throw ''
          Access to targets under //${folder} is not permitted from
          other repository paths. Specific exceptions are configured
          at the top-level.

          ${reason}
          At location: ${builtins.concatStringsSep "." parts}
        '';
      };
    };
}
