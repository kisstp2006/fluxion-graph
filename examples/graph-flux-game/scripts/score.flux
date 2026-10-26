// The score, in Flux: what score.fxgraph does as a graph, written by hand -
// the same fields, signal and methods, so either can be the score.
const helpers = @import("helpers.flux");
const math = @import("math");

struct Score {
    var total: int = 0;
    var ranks: [string] = [];
    var heard: int = 0;
    var root: float = 0.0;
    signal changed(total: int);

    fn ready(self) {
        app.find("Player").?.script().collected.connect(self.on_heard);
    }

    fn on_heard(self, points: int) {
        self.heard += 1;
    }

    fn on_collected(self, points: int) {
        self.total += points;
        switch (helpers.rank_of(self.total)) {
            .gold => self.ranks.push("gold"),
            .silver => self.ranks.push("silver"),
            else => self.ranks.push("bronze"),
        }
        self.root = math.sqrt(float(self.total));
        print(f"score {self.total}");
        self.changed.emit(self.total);
    }

    fn summary(self) string {
        return f"{self.total} from {self.ranks.len}";
    }
}
