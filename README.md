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

## Example

`examples/coauthorship.zig` models a small research community as a directed hypergraph
where vertices are researchers and hyperedges are papers. The first listed author is
treated as the corresponding author, giving each hyperedge a natural direction.

```
zig build example
```

It walks through nine features of the library in sequence:

| Section                  | API                      | What it shows                                               |
| ------------------------ | ------------------------ | ----------------------------------------------------------- |
| Papers per researcher    | `getVertexHyperedges`    | reverse-index query                                         |
| Research communities     | `getConnectedComponents` | two isolated groups with no cross-group papers              |
| Betweenness centrality   | `computeCentrality`      | which researchers bridge the most collaboration paths       |
| Degrees of separation    | `findShortestPath`       | 1–3 hops within a community; unreachable across communities |
| Dual: paper-centric view | `getDual`                | swap vertices ↔ hyperedges to see each researcher's papers  |
| Shared authorship        | `getIntersections`       | researchers present on every paper in a given set           |
| Seniority ordering       | `topologicalSort`        | hierarchy implied by the authorship direction               |
| Pairwise expansion       | `expandToGraph`          | 6 papers encode 11 directed pairs in a regular graph        |

## Documentation

The latest online documentation can be found [here](https://yamafaktory.github.io/hypergraphz/).
