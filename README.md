# HypergraphZ - A Hypergraph Implementation in Zig

![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/yamafaktory/hypergraphz/ci.yml?branch=main&style=flat-square)

HypergraphZ is a directed hypergraph implementation in Zig (https://en.wikipedia.org/wiki/Hypergraph):

- Each hyperedge can contain zero, one (unary) or multiple vertices.
- Each hyperedge can contain vertices directed to themselves one or more times.

## Usage

Add `hypergraphz` as a dependency to your `build.zig.zon`:

```sh
zig fetch --save https://github.com/yamafaktory/hypergraphz/archive/<commit-hash>.tar.gz
```

Add `hypergraphz` as a dependency to your `build.zig`:

```zig
const hypergraphz = b.dependency("hypergraphz", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("hypergraphz", hypergraphz.module("hypergraphz"));
```

## Documentation

The latest online documentation can be found [here](https://yamafaktory.github.io/hypergraphz/).
