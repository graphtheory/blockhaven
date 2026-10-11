import Foundation

/// Tracks how far along breaking the current block is. Progress resets the
/// moment the player looks at a different block or releases the button —
/// the same rule the original uses.
struct MiningState {
    private(set) var target: (x: Int, y: Int, z: Int)?
    private(set) var progress: Double = 0

    /// Advances mining. Returns true on the frame the block breaks.
    mutating func update(
        dt: Double,
        target newTarget: (x: Int, y: Int, z: Int)?,
        block: BlockType?,
        tool: ItemType?,
        isMining: Bool,
        fixedTime: Double? = nil
    ) -> Bool {
        guard isMining, let newTarget, let block, block.hardness.isFinite else {
            reset()
            return false
        }
        if let current = target {
            if current.x != newTarget.x || current.y != newTarget.y || current.z != newTarget.z {
                target = newTarget
                progress = 0
            }
        } else {
            target = newTarget
            progress = 0
        }
        // A fixed time (creative's 0.05 s) overrides hardness and tool.
        progress += dt / (fixedTime ?? MiningState.breakSeconds(for: block, tool: tool))
        if progress >= 1 {
            reset()
            return true
        }
        return false
    }

    mutating func reset() {
        target = nil
        progress = 0
    }

    /// How long this block takes with this tool. A matching tool applies
    /// its tier multiplier; bare hands on something that wants a tool are
    /// punishingly slow, as they should be.
    static func breakSeconds(for block: BlockType, tool: ItemType?) -> Double {
        var speed = 1.0
        if let tool, let toolClass = tool.toolClass, toolClass == block.toolClass {
            speed = tool.toolTier.speedMultiplier
        }
        let tier = tool?.toolTier ?? .hand
        if block.requiresTool, tier < block.minimumTier {
            speed *= 0.2
        }
        return max(0.05, block.hardness / speed)
    }
}
