extension EmbeddedBrowserNavigationState {
    /// Same-document commits and stopped loads must not leave an activity bar stuck.
    var showsNavigationProgress: Bool {
        guard structuredError == nil, visibleError == nil else { return false }
        switch phase {
        case .creating: return true
        case .loading, .committed: return isLoading
        default: return false
        }
    }
}
