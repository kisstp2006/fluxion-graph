// The referee, in Flux: once the run is over, it looks at what the graphs
// did and says whether it is all as it should be.
const score_graph = @import("score.fxgraph");

struct Referee {
    var changes: int = 0;

    fn ready(self) {
        // Flux connects to a graph's own signal.
        const score = app.find("Score").?.script();
        score.changed.connect(self.on_changed);
        self.judge();
    }

    fn on_changed(self, total: int) {
        self.changes += 1;
    }

    fn judge(self) {
        await wait(2.0);
        const score: score_graph.Score = app.find("Score").?.script();
        var wrong: [string] = [];
        if (score.total != 70) wrong.push(f"total is {score.total}, not 70");
        if (score.ranks != ["silver", "gold", "gold"]) wrong.push(f"ranks are {score.ranks}");
        if (score.heard != 3) wrong.push(f"the score heard the runner {score.heard} times in code, not 3");
        if (self.changes != 3) wrong.push(f"the referee heard the score {self.changes} times, not 3");
        if (score.summary() != "70 from 3") wrong.push(f"the summary is {score.summary()}");
        if (score.root < 8.3 or score.root > 8.4) wrong.push(f"the root is {score.root}");
        for (["Coin1", "Coin2", "Coin3"]) |name| {
            if (app.find(name) != null) wrong.push(f"{name} is still there");
        }
        const spun = app.find("Spinner").?.get(Transform2D).rotation;
        if (spun < 1.0) wrong.push(f"the spinner turned only {spun}");
        if (wrong.len == 0) {
            print("REFEREE PASS: Flux and graphs did all of it together");
        } else {
            for (wrong) |w| print("REFEREE FAIL:", w);
        }
        app.quit();
    }
}
