# HyperZig - A Hypergraph Implementation in Zig

![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/yamafaktory/hyperzig/ci.yml?branch=main&style=flat-square)

HyperZig is a directed hypergraph implementation in Zig (https://en.wikipedia.org/wiki/Hypergraph):

- Each hyperedge can contain zero, one (unary) or multiple vertices.
- Each hyperedge can contain vertices directed to themselves one or more times.

## Usage

Add `hyperzig` as a dependency to your `build.zig.zon`:

```sh
zig fetch --save https://github.com/yamafaktory/hyperzig/archive/<commit-hash>.tar.gz
```

Add `hyperzig` as a dependency to your `build.zig`:

```zig
const hyperzig = b.dependency("hyperzig", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("hyperzig", hyperzig.module("hyperzig"));
```

## Documentation

The latest online documentation can be found [here](https://yamafaktory.github.io/hyperzig/).
