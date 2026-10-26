// The runner, in Flux: it runs right, and as it reaches a coin - a graph -
// calls the coin's methods and says what it picked.
const coin_graph = @import("coin.fxgraph");

struct Runner {
    @export var speed: float = 200.0;
    var picked: [string] = [];
    signal collected(points: int);

    fn update(self, dt: float) {
        const t = self.entity.get(Transform2D);
        t.x += self.speed * dt;
        for (["Coin1", "Coin2", "Coin3"]) |name| {
            if (name in self.picked) continue;
            const coin = app.find(name) orelse continue;
            if (coin.get(Transform2D).x > t.x) continue;
            self.picked.push(name);
            // A graph's struct, called from Flux as any of Flux's.
            const it: coin_graph.Coin = coin.script();
            const points = it.worth();
            it.pick(self.entity);
            self.collected.emit(points);
        }
    }
}
