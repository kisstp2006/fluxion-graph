# Fluxion Graph

Scripts drawn as graphs of nodes, for the [Fluxion engine](https://github.com/kisstp2006/fluxion-engine).

A graph is not a language of its own with a machine of its own. It compiles to [Flux](https://github.com/kisstp2006/fluxion-script), and the Flux VM runs it as it runs Flux written by hand. O3DE's Script Canvas does the same with Lua. A graph and a Flux file therefore:

- use the same engine and the same `app`;
- can import each other;
- reload while the game runs;
- show their `@export`s in the editor's Inspector;
- ship compiled.

## A graph

A `.fxgraph` file is one struct of Flux's, drawn:

- **variables**, the struct's fields (`@export` ones shown in the Inspector);
- **signals**, the struct's own;
- **functions**, each the graph of nodes that is its body. An *event* is one the engine calls (`update`, `input`) or a signal's handler; any other function is one that nodes and scripts call.

A node is either:

- an **action**, run in order along the links of its run pins;
- an **expression**, worked out when an action wants its value.

As the struct a `.flux` file is, a graph goes onto an entity as its `Script`.

The file is JSON. A node's `kind` is the name the catalog gives it (`flow.branch`, `call:Transform2D.rotate`), and a link joins two pins by their names. A graph therefore keeps every node a newer catalog or a missing plugin has, and a catalog that reorders a kind's pins breaks no link.

```json
{
  "fluxion_graph": 1,
  "name": "Door",
  "variables": [{ "name": "speed", "type": "float", "default": 2.0, "exported": true }],
  "functions": [
    {
      "name": "update",
      "kind": "event",
      "params": [{ "name": "dt", "type": "float" }],
      "nodes": [
        { "id": 1, "kind": "entry" },
        { "id": 2, "kind": "call:Transform2D.rotate", "at": [240.0, 0.0] }
      ],
      "links": [{ "from": { "node": 1, "pin": "then" }, "to": { "node": 2, "pin": "run" } }],
      "next_id": 3
    }
  ]
}
```

## Pieces

| | What it is |
| --- | --- |
| `model` | What a graph's file holds: `File`, `Variable`, `Signal`, `Function`, `Node`, `Link`. |
| `Graph` | A graph read, changed and written: its file and the memory it lives in, with the edits an editor makes (imports, functions, variables, signals, nodes, links, a pin's value). |
| `compile` | A graph made into Flux text, with each line kept with the node it came from (`Compiled.lineAt`), and what cannot be written said at its node (`Problem`). |

## Nodes

A node that calls carries what it calls in the file: what it is called on (`self`, the entity, a component, a global or module, or what its `target` pin is given), the name, its argument pins in order, and whether it gives a value, runs in order and is waited for. A graph therefore compiles with nothing but itself, and a game's runtime needs no catalog.

The other kinds:

| Kind | What it is |
| --- | --- |
| `entry` | Where a function starts: `then`, and its parameters as outputs. |
| `var.get`, `var.set` | Read or set the variable `member`. |
| `signal.emit` | Emit the signal `member`, its parameters as inputs. |
| `literal` | The value its `value` pin is given, as a `type`. |
| `math.*`, `compare.*`, `logic.*`, `make.vec2/vec3/color`, `convert.to_float/to_int`, `self`, `self.entity` | Expressions. |
| `flow.branch` | `condition`, and the runs `true` and `false`. |
| `flow.sequence` | The runs `then_0`, `then_1`, and on, one after another. |
| `flow.for_each`, `flow.repeat`, `flow.while` | Loops: `body`, then `then`. `item` and `index` inside. |
| `flow.wait`, `flow.print`, `flow.return` | `await wait(seconds)`, `print(value)`, `return`. |

Run pins are `run` in and `then` out; a call's value is `result`.

## To come

1. **The catalog.** The node kinds there are. A node for each of the engine's types, methods, signals and hooks, and for each function of the project's Flux, is not written by hand: it is read from the same place Flux's completions come from. Anything a plugin gives Flux is therefore a node too.
2. **The editor widget** (`fluxion_graph_ui`), built on [fluxion-ui](https://github.com/kisstp2006/fluxion-ui) as [fluxion-code](https://github.com/kisstp2006/fluxion-code) is.

## Building

Zig 0.17.0.

```
zig build test
```

## License

BSD-2-Clause.
