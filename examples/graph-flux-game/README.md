# Graph and Flux

A small game that tests whether Flux scripts and graphs (`.fxgraph`, fluxion-graph) work together in the real runtime, and whether each can do what the other does.

A runner runs right and picks up three coins. A score adds up what they are worth and ranks it. A spinner turns. After two seconds, a referee checks what each did and prints `REFEREE PASS` or what was wrong, then quits.

There are two scenes:

| Scene | Runner | Coins | Score | Referee |
| --- | --- | --- | --- | --- |
| `levels/meadow.json` | `runner.flux` | `coin.fxgraph` | `score.fxgraph` | `referee.flux` |
| `levels/swapped.json` | `runner.fxgraph` | `coin.fxgraph` | `score.flux` | `referee.fxgraph` |

In both scenes the scripts do these things:

- **Calls between the languages.** Flux calls a graph's methods: `worth`, and `pick`, which is a coroutine. A graph calls Flux's functions (`helpers.bonus`, `helpers.rank_of`). Each takes the other's struct as a type of its own.
- **Signals between the languages.** Signals cross both ways, through a connection the scene makes and through ones each makes in code.
- **What a graph does as Flux does.** The graph scripts use exported fields given by the scene, a switch on a Flux enum, lists, text with values in it, loops, locals, `await`, `math`, and calls on another entity's script and component.

The graphs are written by `tools/make_graphs.py`, as the editor writes them. To play both scenes with a built runtime, run:

```
tools/run.sh <path to fluxion-runtime>
```

`fluxion-graph-flux scripts/<name>.fxgraph` (from fluxion-graph) prints the Flux a graph is made into.
