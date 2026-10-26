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
| `catalog` | The kinds of node there are, each with its pins and the node it makes: built from `flux.service.catalog` and the graph's own variables, signals and functions; and `check`, the links checked by their pins' types. |
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

`member.get` and `member.set` read and set a field of what their `call` names, as a call is made on it.

Run pins are `run` in and `then` out; a call's value is `result`.

## The catalog

No node of the engine's is written here. `catalog.build` reads them from `flux.service.catalog`, which is the place Flux's completions come from, so whatever the engine, the project's Flux or a plugin gives scripts is a node too:

- each method of a component, on the graph's entity, and of any of the host's types, on a value a link brings;
- each field, as a node that reads it and one that sets it;
- each global's methods (`app.find`);
- each hook (`update`) as an event that starts a function;
- each built-in function, and each function of a file the graph may import, with the import added with the node.

A method is an action: it runs in order. A built-in that changes nothing (`clamp`, `vec2`), and a Flux function marked `@pure`, is an expression. A Flux function's `@node("Weather", "cloud")` puts it in the chooser's group `Weather`, with the icon `cloud`.

## The editor widget

`fluxion_graph_ui` draws a function's graph with [fluxion-ui](https://github.com/kisstp2006/fluxion-ui), as [fluxion-code](https://github.com/kisstp2006/fluxion-code) draws code. It has these parts:

| | What it is |
| --- | --- |
| `View` | The graph drawn: a canvas with a grid, each node a box with a coloured header, its inputs down the left and outputs down the right, each pin a dot in its type's colour (the run white), and links hanging from output to input. `pointer` and `key` do what the hand does to it. |
| `Canvas` | What a view keeps between frames: where it is moved to and how near, which nodes are picked, and what the pointer is doing. |
| `Theme` | Its colours, a pin's by its type and a header's by what the node does. |
| `layout` | Where the nodes and pins are: sizes, pin points, what is under a point, a link's curve. Arithmetic only, so the view draws and the pointer finds the same places. |

What the hand does to it:

- the wheel zooms about the pointer, and the middle button (or Alt and the left) moves the canvas;
- a press picks a node (with Shift, adds or takes one out), and a drag moves what is picked;
- a drag from a pin draws a link, which is made if it is let go on a pin that fits;
- a drag from an input a link feeds takes that link off;
- a drag on nothing picks what is in its box;
- Delete, Ctrl+A and F take out, pick all and show all.

What a pin is given, and which node to make (`Outcome.choose`: let go on nothing, a second press, the right button), are the program's to ask. Each `Outcome` that says `changed` is one step to undo.

## Building

Zig 0.17.0.

```
zig build test
```

## License

BSD-2-Clause.
