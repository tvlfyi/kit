readTree
========

This is a Nix program that builds up an attribute set tree for a large
repository based on the filesystem layout.

It is in fact the tool that lays out the attribute set of this repository.

As an example, consider a root (`.`) of a repository and a layout such as:

```
.
├── third_party
│   ├── default.nix
│   └── rustpkgs
│       ├── aho-corasick.nix
│       └── serde.nix
└── tools
    ├── cheddar
    │   └── default.nix
    └── roquefort.nix
```

When `readTree` is called on that tree, it will construct an attribute set with
this shape:

```nix
{
    tools = {
        cheddar = ...;
        roquefort = ...;
    };

    third_party = {
        # the `default.nix` of this folder might have had arbitrary other
        # attributes here, such as this:
        favouriteColour = "orange";

        rustpkgs = {
            aho-corasick = ...;
            serde = ...;
        };
    };
}
```

Every imported Nix file that yields an attribute set will have a `__readTree =
true;` attribute merged into it.

## Traversal logic

`readTree` will follow any subdirectories of a tree and import all Nix files,
with some exceptions:

* A folder can declare that its children are off-limit by containing a
  `.skip-subtree` file. Since the content of the file is not checked, it can be
  useful to leave a note for a human in the file.
* If a folder contains a `default.nix` file, no *sibling* Nix files will be
  imported - however children are traversed as normal.
* If a folder contains a `default.nix` it is loaded and, if it evaluates to a
  set, *merged* with the children. If it evaluates to anything else the children
  are *not traversed*.

Traversal is lazy, `readTree` will only build up the tree as requested. This
currently has the downside that directories with no importable files end up in
the tree as empty nodes (`{}`).

## Import structure

`readTree` is called with two parameters: The arguments to pass to all imports,
and the initial path at which to start the traversal.

The package headers in this repository follow the form `{ pkgs, ... }:` where
`pkgs` is a fixed-point of the entire package tree (see the `default.nix` at the
root of the depot).

In theory `readTree` can pass arguments of different shapes, but I have found
this to be a good solution for the most part.

Note that `readTree` does not currently make functions overridable, though it is
feasible that it could do that in the future.
