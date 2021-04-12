# Copyright (c) 2019 Vincent Ambo
# Copyright (c) 2020-2021 The TVL Authors
# SPDX-License-Identifier: MIT
#
# Provides a function to automatically read a a filesystem structure
# into a Nix attribute set.
{ ... }:

let
  inherit (builtins)
    attrNames
    baseNameOf
    concatStringsSep
    filter
    hasAttr
    head
    isAttrs
    length
    listToAttrs
    map
    match
    readDir
    substring;

  assertMsg = pred: msg:
    if pred
    then true
    else builtins.trace msg false;

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

  # Create a mark containing the location of this attribute.
  marker = parts: {
    __readTree = parts;
  };

  # The marker is added to every set that was imported directly by
  # readTree.
  importWithMark = args: path: parts:
    let
      importedFile = import path;
      pathType = builtins.typeOf importedFile;
      imported =
        assert assertMsg
          (pathType == "lambda")
          "readTree: trying to import ${toString path}, but it’s a ${pathType}, you need to make it a function like { depot, pkgs, ... }";
        importedFile (argsWithPath args parts);
    in if (isAttrs imported)
      then imported // (marker parts)
      else imported;

  nixFileName = file:
    let res = match "(.*)\\.nix" file;
    in if res == null then null else head res;

  readTree = args: initPath: parts:
    let
      dir = readDirVisible initPath;
      self = importWithMark args initPath parts;
      joinChild = c: initPath + ("/" + c);

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
        value = readTree args (joinChild c) (parts ++ [ c ]);
      }) (filter filterDir (attrNames dir));

      # Import Nix files
      nixFiles = filter (f: f != null) (map nixFileName (attrNames dir));
      nixChildren = map (c: let p = joinChild (c + ".nix"); in {
        name = c;
        value = importWithMark args p (parts ++ [ c ]);
      }) nixFiles;
    in if dir ? "default.nix"
      then (if isAttrs self then self // (listToAttrs children) else self)
      else (listToAttrs (nixChildren ++ children) // (marker parts));

in {
   __functor = _: args: initPath: readTree args initPath [ (baseNameOf initPath) ];
}
