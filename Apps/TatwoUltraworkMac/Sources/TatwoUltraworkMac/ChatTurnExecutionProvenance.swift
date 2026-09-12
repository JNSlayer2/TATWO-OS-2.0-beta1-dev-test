import Foundation
import TatwoUltraworkCore

/// One immutable execution-provenance snapshot per physical Chat turn.
///
/// 2026-08-27 live regression (staging61, turn `2BD193BD…`): inside a single
/// turn the canonical transcript journal recorded `command` events stamped
/// `gpt-5.5` while the `result` event of the same turn was stamped
/// `gpt-5.6-terra`. The two sides read different authorities:
///
/// * command/activity events were built from the *mutable* model picker
///   (`ChatPageModel.routeChoice`) at append time, and
/// * the result event was projected from `ChatMessage.modelID`, which is
///   frozen from this turn's dispatch snapshot at spawn time.
///
/// Any mid-turn route change — an Ultrawork topology mutation, a
/// `下一輪` pending route, an executor realignment — therefore split the
/// provenance of one run across two model identities.
///
/// This value is captured once, at the spawn boundary, from exactly the
/// identities the assistant message is stamped with. Both sides now read it,
/// so command and result attribution agree by construction instead of being
/// repainted after execution.
struct ChatTurnExecutionProvenance: Equatable {
    /// Runner run identity this provenance belongs to.
    let runID: String
    /// Assistant turn (message) identity this provenance belongs to.
    let turnID: String
    /// Route identity, identical to the value stamped on `ChatMessage.modelID`.
    let modelID: String
    /// Canonical model slug of the frozen route.
    let canonicalModelID: String
    /// Runtime adapter actually used to spawn, identical to the value stamped
    /// on `ChatMessage.runtimeAdapterID`.
    let runtimeAdapterID: String
    /// Provider identity used by the canonical transcript journal.
    let providerID: String

    func matches(runID candidate: String) -> Bool {
        runID == candidate
    }

    /// Returns a copy carrying a replacement runtime adapter.
    ///
    /// Native-governance fallback rewrites the live assistant message's
    /// `runtimeAdapterID` after the turn started; provenance must follow it or
    /// the two sides disagree again on `runtime`.
    func replacingRuntimeAdapterID(
        _ replacement: String
    ) -> ChatTurnExecutionProvenance {
        ChatTurnExecutionProvenance(
            runID: runID,
            turnID: turnID,
            modelID: modelID,
            canonicalModelID: canonicalModelID,
            runtimeAdapterID: replacement,
            providerID: providerID)
    }
}
