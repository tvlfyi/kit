The TVL Kit
===========

[![Build status](https://badge.buildkite.com/cd7240a881c7e77c3ed8cc040f81734623f57038563b37213d.svg?branch=canon)](https://buildkite.com/tvl/tvl-kit)

This folder contains a publicly available version of the core TVL
tooling, currently comprising of:

* `buildkite`: TVL tooling for dynamically generating Buildkite
  pipelines with Nix.
* `buildGo`: Nix-based build system for Go.
* `readTree`: Nix library to dynamically compute attribute trees
  corresponding to the physical layout of a repository.
* `besadii`: Configurable Gerrit/Buildkite integration hook.
* `magrathea`: Command-line tool for working with TVL-style monorepos
* `checks`: Collection of useful CI checks for Buildkite

It can be accessed via git by cloning it as such:

    git clone https://code.tvl.fyi/depot.git:workspace=views/kit.git tvl-kit

If you are looking at this within the TVL depot, you can see the
[josh][] configuration in `workspace.josh`. You will find the projects
at slightly different paths within the depot.

[josh]: https://github.com/josh-project/josh/
