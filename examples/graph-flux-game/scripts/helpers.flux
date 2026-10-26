/// How well the run is going.
enum Rank { bronze, silver, gold }

/// A coin's worth: twice its value. A graph calls it as a node.
@node("Scoring", "star") @pure fn bonus(n: int) int {
    return n * 2;
}

/// The rank a score earns.
@pure fn rank_of(points: int) Rank {
    if (points >= 30) return .gold;
    if (points >= 10) return .silver;
    return .bronze;
}
