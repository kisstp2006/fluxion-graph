#!/usr/bin/env python3
"""The game's graphs, written as the editor writes them: each node, its
links and what its pins are given. Run from the project's folder."""

import json
import pathlib


class Function:
    def __init__(self, name, kind, params=(), result=""):
        self.data = {"name": name, "kind": kind, "params": [{"name": n, "type": t} for n, t in params],
                     "result": result, "locals": [], "nodes": [{"id": 1, "kind": "entry", "at": [0.0, 0.0]}],
                     "links": [], "next_id": 2}
        self.x = 220.0

    def node(self, kind, **fields):
        nid = self.data["next_id"]
        self.data["next_id"] += 1
        values = fields.pop("values", {})
        n = {"id": nid, "kind": kind, "at": [self.x, 0.0]}
        n.update(fields)
        if values:
            n["values"] = [{"pin": p, "value": v} for p, v in values.items()]
        self.data["nodes"].append(n)
        self.x += 220.0
        return nid

    def link(self, a, a_pin, b, b_pin):
        self.data["links"].append({"from": {"node": a, "pin": a_pin}, "to": {"node": b, "pin": b_pin}})

    def run(self, a, b, a_pin="then"):
        self.link(a, a_pin, b, "run")

    def local(self, name, type, default=None):
        self.data["locals"].append({"name": name, "type": type, "default": default})


def call(on, name, of="", args=(), gives=False, action=True, waits=False):
    return {"on": on, "of": of, "name": name, "args": list(args), "gives": gives, "action": action, "waits": waits}


def graph(name, imports=(), variables=(), signals=(), functions=()):
    return {"fluxion_graph": 1, "name": name,
            "imports": [{"name": n, "path": p} for n, p in imports],
            "variables": list(variables), "signals": list(signals),
            "functions": [f.data for f in functions]}


def variable(name, type, default=None, exported=False):
    return {"name": name, "type": type, "default": default, "exported": exported}


# ---------------------------------------------------------------------------
# A coin: it spins, says what it is worth through a Flux function, and when
# picked says by whom, waits, and goes.

update = Function("update", "event", [("dt", "float")])
rotation = call("component", "rotation", of="Transform2D", action=False)
get_rot = update.node("member.get", call=rotation)
spin = update.node("var.get", member="spin")
times = update.node("math.multiply")
plus = update.node("math.add")
set_rot = update.node("member.set", call=dict(rotation, action=True))
update.link(1, "dt", times, "a")
update.link(spin, "out", times, "b")
update.link(get_rot, "out", plus, "a")
update.link(times, "out", plus, "b")
update.run(1, set_rot)
update.link(plus, "out", set_rot, "value")

worth = Function("worth", "function", result="int")
value = worth.node("var.get", member="value")
bonus = worth.node("call", call=call("global", "bonus", of="helpers", args=["n"], gives=True, action=False))
done = worth.node("flow.return")
worth.link(value, "out", bonus, "n")
worth.run(1, done)
worth.link(bonus, "result", done, "value")

pick = Function("pick", "function", [("by", "Entity")])
mark = pick.node("var.set", member="picked", values={"value": True})
who = pick.node("call", call=call("target", "name", of="Entity", gives=True, action=False))
words = pick.node("make.text", member="picked by {who}")
say = pick.node("flow.print")
pause = pick.node("flow.await", values={"value": 0.05})
gone = pick.node("call", call=call("entity", "despawn"))
pick.run(1, mark)
pick.link(1, "by", who, "target")
pick.link(who, "result", words, "who")
pick.run(mark, say)
pick.link(words, "out", say, "value")
pick.run(say, pause)
pick.run(pause, gone)

coin = graph("Coin", imports=[("helpers", "helpers.flux")],
             variables=[variable("value", "int", 5, True), variable("spin", "float", 3.0, True), variable("picked", "bool", False)],
             functions=[update, worth, pick])

# ---------------------------------------------------------------------------
# The score: it hears the runner by a connection the scene makes and by one
# it makes itself, ranks the total by a Flux enum, keeps the ranks in a list,
# takes a root with `math`, and says when it changed.

ready = Function("ready", "event")
find = ready.node("call", call=call("global", "find", of="app", args=["name"], gives=True), values={"name": "Player"})
sure = ready.node("value.unwrap")
script = ready.node("call", call=call("target", "script", of="any", gives=True))
said = ready.node("member.get", call=call("target", "collected", of="any", action=False))
heard_ref = ready.node("function.ref", member="on_heard")
hook = ready.node("call", call=call("target", "connect", of="signal", args=["target_fn"]))
ready.run(1, find)
ready.link(find, "result", sure, "value")
ready.run(find, script)
ready.link(sure, "out", script, "target")
ready.run(script, hook)
ready.link(script, "result", said, "target")
ready.link(said, "out", hook, "target")
ready.link(heard_ref, "out", hook, "target_fn")

heard = Function("on_heard", "function", [("points", "int")])
count = heard.node("var.get", member="heard")
up = heard.node("math.add", values={"b": 1})
again = heard.node("var.set", member="heard")
heard.link(count, "out", up, "a")
heard.run(1, again)
heard.link(up, "out", again, "value")

collected = Function("on_collected", "function", [("points", "int")])
total = collected.node("var.get", member="total")
more = collected.node("math.add")
keep = collected.node("var.set", member="total")
collected.link(total, "out", more, "a")
collected.link(1, "points", more, "b")
collected.run(1, keep)
collected.link(more, "out", keep, "value")
rank = collected.node("call", call=call("global", "rank_of", of="helpers", args=["points"], gives=True, action=False))
collected.link(total, "out", rank, "points")
choose = collected.node("flow.switch", call=call("none", "switch", args=[".gold", ".silver"]))
collected.run(keep, choose)
collected.link(rank, "out" if False else "result", choose, "value")
ranks = collected.node("var.get", member="ranks")
for case, word in (("case_0", "gold"), ("case_1", "silver"), ("else", "bronze")):
    push = collected.node("call", call=call("target", "push", of="list", args=["value"]), values={"value": word})
    collected.run(choose, push, case)
    collected.link(ranks, "out", push, "target")
as_float = collected.node("convert.to_float")
root = collected.node("call", call=call("global", "sqrt", of="math", args=["x"], gives=True, action=False))
keep_root = collected.node("var.set", member="root")
collected.link(total, "out", as_float, "value")
collected.link(as_float, "out", root, "x")
collected.run(choose, keep_root)
collected.link(root, "result", keep_root, "value")
tell = collected.node("make.text", member="score {total}")
say_score = collected.node("flow.print")
collected.link(total, "out", tell, "total")
collected.run(keep_root, say_score)
collected.link(tell, "out", say_score, "value")
emit = collected.node("signal.emit", member="changed")
collected.run(say_score, emit)
collected.link(total, "out", emit, "total")

summary = Function("summary", "function", result="string")
summary.local("count", "int", 0)
listed = summary.node("var.get", member="ranks")
each = summary.node("flow.for_each")
counted = summary.node("local.get", member="count")
plus_one = summary.node("math.add", values={"b": 1})
recount = summary.node("local.set", member="count")
out = summary.node("make.text", member="{total} from {count}")
total_now = summary.node("var.get", member="total")
back = summary.node("flow.return")
summary.run(1, each)
summary.link(listed, "out", each, "list")
summary.run(each, recount, "body")
summary.link(counted, "out", plus_one, "a")
summary.link(plus_one, "out", recount, "value")
summary.run(each, back)
summary.link(total_now, "out", out, "total")
summary.link(counted, "out", out, "count")
summary.link(out, "out", back, "value")

score = graph("Score", imports=[("helpers", "helpers.flux"), ("math", "math")],
              variables=[variable("total", "int", 0), variable("ranks", "[string]"), variable("heard", "int", 0), variable("root", "float", 0.0)],
              signals=[{"name": "changed", "params": [{"name": "total", "type": "int"}]}],
              functions=[ready, heard, collected, summary])

here = pathlib.Path("scripts")
for name, made in (("coin", coin), ("score", score)):
    (here / f"{name}.fxgraph").write_text(json.dumps(made, indent=2) + "\n")
print("graphs written")

# ---------------------------------------------------------------------------
# The other way round: the runner and the referee as graphs, doing what
# runner.flux and referee.flux do, beside score.flux.

update = Function("update", "event", [("dt", "float")])
x_of = call("component", "x", of="Transform2D", action=False)
get_x = update.node("member.get", call=x_of)
speed = update.node("var.get", member="speed")
step = update.node("math.multiply")
moved = update.node("math.add")
set_x = update.node("member.set", call=dict(x_of, action=True))
update.link(1, "dt", step, "a")
update.link(speed, "out", step, "b")
update.link(get_x, "out", moved, "a")
update.link(step, "out", moved, "b")
update.run(1, set_x)
update.link(moved, "out", set_x, "value")
names = update.node("literal", type="[string]", values={"value": ["Coin1", "Coin2", "Coin3"]})
each = update.node("flow.for_each")
update.run(set_x, each)
update.link(names, "out", each, "list")
picked = update.node("var.get", member="picked")
seen = update.node("compare.in")
update.link(each, "item", seen, "a")
update.link(picked, "out", seen, "b")
skip_seen = update.node("flow.branch")
update.run(each, skip_seen, "body")
update.link(seen, "out", skip_seen, "condition")
again1 = update.node("flow.continue")
update.run(skip_seen, again1, "true")
find_coin = update.node("call", call=call("global", "find", of="app", args=["name"], gives=True))
update.run(skip_seen, find_coin, "false")
update.link(each, "item", find_coin, "name")
missing = update.node("compare.is_null")
update.link(find_coin, "result", missing, "value")
skip_missing = update.node("flow.branch")
update.run(find_coin, skip_missing)
update.link(missing, "out", skip_missing, "condition")
again2 = update.node("flow.continue")
update.run(skip_missing, again2, "true")
coin_entity = update.node("value.unwrap")
update.link(find_coin, "result", coin_entity, "value")
coin_place = update.node("entity.component", type="Transform2D")
update.link(coin_entity, "out", coin_place, "entity")
coin_x = update.node("member.get", call=call("target", "x", of="Transform2D", action=False))
update.link(coin_place, "out", coin_x, "target")
ahead = update.node("compare.greater")
update.link(coin_x, "out", ahead, "a")
update.link(get_x, "out", ahead, "b")
skip_ahead = update.node("flow.branch")
update.run(skip_missing, skip_ahead, "false")
update.link(ahead, "out", skip_ahead, "condition")
again3 = update.node("flow.continue")
update.run(skip_ahead, again3, "true")
push = update.node("call", call=call("target", "push", of="list", args=["value"]))
update.run(skip_ahead, push, "false")
update.link(picked, "out", push, "target")
update.link(each, "item", push, "value")
its = update.node("call", call=call("target", "script", of="any", gives=True))
update.run(push, its)
update.link(coin_entity, "out", its, "target")
worth_it = update.node("call", call=call("target", "worth", of="any", gives=True))
update.run(its, worth_it)
update.link(its, "result", worth_it, "target")
me = update.node("self.entity")
pick_it = update.node("call", call=call("target", "pick", of="any", args=["by"]))
update.run(worth_it, pick_it)
update.link(its, "result", pick_it, "target")
update.link(me, "out", pick_it, "by")
say_it = update.node("signal.emit", member="collected")
update.run(pick_it, say_it)
update.link(worth_it, "result", say_it, "points")

runner = graph("Runner", variables=[variable("speed", "float", 200.0, True), variable("picked", "[string]")],
               signals=[{"name": "collected", "params": [{"name": "points", "type": "int"}]}],
               functions=[update])

ready = Function("ready", "event")
find_score = ready.node("call", call=call("global", "find", of="app", args=["name"], gives=True), values={"name": "Score"})
score_entity = ready.node("value.unwrap")
ready.link(find_score, "result", score_entity, "value")
score_script = ready.node("call", call=call("target", "script", of="any", gives=True))
changed = ready.node("member.get", call=call("target", "changed", of="any", action=False))
on_changed_ref = ready.node("function.ref", member="on_changed")
hook = ready.node("call", call=call("target", "connect", of="signal", args=["target_fn"]))
ready.run(1, find_score)
ready.run(find_score, score_script)
ready.link(score_entity, "out", score_script, "target")
ready.run(score_script, hook)
ready.link(score_script, "result", changed, "target")
ready.link(changed, "out", hook, "target")
ready.link(on_changed_ref, "out", hook, "target_fn")
pause = ready.node("flow.await", values={"value": 2.0})
ready.run(hook, pause)
ready.local("wrong", "[string]")
wrong = ready.node("local.get", member="wrong")
score_now = ready.node("call", call=call("target", "script", of="any", gives=True))
ready.run(pause, score_now)
ready.link(score_entity, "out", score_now, "target")
checks = ready.node("flow.sequence")
ready.run(score_now, checks)


def field(name):
    n = ready.node("member.get", call=call("target", name, of="any", action=False))
    ready.link(score_now, "result", n, "target")
    return n


def check(index, condition, words, **pins):
    """When `condition` holds, `words` - with each pin a node's `out` - go on the list."""
    branch = ready.node("flow.branch")
    ready.run(checks, branch, f"then_{index}")
    ready.link(condition, "out", branch, "condition")
    told = ready.node("make.text", member=words)
    for pin, source in pins.items():
        ready.link(source, "out", told, pin)
    push = ready.node("call", call=call("target", "push", of="list", args=["value"]))
    ready.run(branch, push, "true")
    ready.link(wrong, "out", push, "target")
    ready.link(told, "out", push, "value")


total = field("total")
c = ready.node("compare.not_equal", values={"b": 70})
ready.link(total, "out", c, "a")
check(0, c, "total is {t}, not 70", t=total)
ranks = field("ranks")
expected = ready.node("literal", type="[string]", values={"value": ["silver", "gold", "gold"]})
c = ready.node("compare.not_equal")
ready.link(ranks, "out", c, "a")
ready.link(expected, "out", c, "b")
check(1, c, "ranks are {r}", r=ranks)
heard = field("heard")
c = ready.node("compare.not_equal", values={"b": 3})
ready.link(heard, "out", c, "a")
check(2, c, "the score heard the runner {h} times in code, not 3", h=heard)
changes = ready.node("var.get", member="changes")
c = ready.node("compare.not_equal", values={"b": 3})
ready.link(changes, "out", c, "a")
check(3, c, "the referee heard the score {n} times, not 3", n=changes)
summary_call = ready.node("call", call=call("target", "summary", of="any", gives=True, action=False))
ready.link(score_now, "result", summary_call, "target")
c = ready.node("compare.not_equal", values={"b": "70 from 3"})
ready.link(summary_call, "result", c, "a")
check(4, c, "the summary is {s}", s=summary_call)
root = field("root")
low = ready.node("compare.less", values={"b": 8.3})
high = ready.node("compare.greater", values={"b": 8.4})
ready.link(root, "out", low, "a")
ready.link(root, "out", high, "a")
either = ready.node("logic.or")
ready.link(low, "out", either, "a")
ready.link(high, "out", either, "b")
check(5, either, "the root is {r}", r=root)
coins = ready.node("literal", type="[string]", values={"value": ["Coin1", "Coin2", "Coin3"]})
each_coin = ready.node("flow.for_each")
ready.run(checks, each_coin, "then_6")
ready.link(coins, "out", each_coin, "list")
still = ready.node("call", call=call("global", "find", of="app", args=["name"], gives=True))
ready.run(each_coin, still, "body")
ready.link(each_coin, "item", still, "name")
there = ready.node("compare.is_null")
ready.link(still, "result", there, "value")
gone_branch = ready.node("flow.branch")
ready.run(still, gone_branch)
ready.link(there, "out", gone_branch, "condition")
told = ready.node("make.text", member="{name} is still there")
ready.link(each_coin, "item", told, "name")
push = ready.node("call", call=call("target", "push", of="list", args=["value"]))
ready.run(gone_branch, push, "false")
ready.link(wrong, "out", push, "target")
ready.link(told, "out", push, "value")
spinner = ready.node("call", call=call("global", "find", of="app", args=["name"], gives=True), values={"name": "Spinner"})
ready.run(checks, spinner, "then_7")
spinner_entity = ready.node("value.unwrap")
ready.link(spinner, "result", spinner_entity, "value")
place = ready.node("entity.component", type="Transform2D")
ready.link(spinner_entity, "out", place, "entity")
spun = ready.node("member.get", call=call("target", "rotation", of="Transform2D", action=False))
ready.link(place, "out", spun, "target")
c = ready.node("compare.less", values={"b": 1.0})
ready.link(spun, "out", c, "a")
spun_branch = ready.node("flow.branch")
ready.run(spinner, spun_branch)
ready.link(c, "out", spun_branch, "condition")
told = ready.node("make.text", member="the spinner turned only {r}")
ready.link(spun, "out", told, "r")
push = ready.node("call", call=call("target", "push", of="list", args=["value"]))
ready.run(spun_branch, push, "true")
ready.link(wrong, "out", push, "target")
ready.link(told, "out", push, "value")
size = ready.node("member.get", call=call("target", "len", of="list", action=False))
ready.link(wrong, "out", size, "target")
none_wrong = ready.node("compare.equal", values={"b": 0})
ready.link(size, "out", none_wrong, "a")
verdict = ready.node("flow.branch")
ready.run(checks, verdict, "then_8")
ready.link(none_wrong, "out", verdict, "condition")
passed = ready.node("flow.print", values={"value": "REFEREE PASS: graphs and Flux did all of it the other way round too"})
ready.run(verdict, passed, "true")
each_wrong = ready.node("flow.for_each")
ready.run(verdict, each_wrong, "false")
ready.link(wrong, "out", each_wrong, "list")
failed = ready.node("make.text", member="REFEREE FAIL: {w}")
ready.link(each_wrong, "item", failed, "w")
say_fail = ready.node("flow.print")
ready.run(each_wrong, say_fail, "body")
ready.link(failed, "out", say_fail, "value")
leave = ready.node("call", call=call("global", "quit", of="app"))
ready.run(checks, leave, "then_9")

on_changed = Function("on_changed", "function", [("total", "int")])
n = on_changed.node("var.get", member="changes")
one_more = on_changed.node("math.add", values={"b": 1})
keep = on_changed.node("var.set", member="changes")
on_changed.link(n, "out", one_more, "a")
on_changed.run(1, keep)
on_changed.link(one_more, "out", keep, "value")

referee = graph("Referee", variables=[variable("changes", "int", 0)], functions=[ready, on_changed])

for name, made in (("runner", runner), ("referee", referee)):
    (here / f"{name}.fxgraph").write_text(json.dumps(made, indent=2) + "\n")
print("the other way round written")
