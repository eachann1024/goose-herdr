/// A device/Agent selection change invalidates every request from the previous selection.
struct UsageRequestGate {
    private(set) var generation = 0
    private(set) var enabled: Set<String> = []

    mutating func replace(enabled: Set<String>) {
        generation += 1
        self.enabled = enabled
    }

    func accepts(provider: String, generation: Int) -> Bool {
        self.generation == generation && enabled.contains(provider)
    }
}
