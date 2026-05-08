import SwiftUI

struct IPadOperationalWorkspaceView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    @State private var selectedTripID: String?
    @State private var selectedBidPeriodID: String?
    @State private var isFriendsOverlayEnabled = false

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            IPadTimelineSidebarView(selectedTripID: $selectedTripID)
                .navigationSplitViewColumnWidth(min: 380, ideal: 420, max: 480)
        } detail: {
            IPadBidPeriodCalendarView(
                selectedTripID: $selectedTripID,
                selectedBidPeriodID: $selectedBidPeriodID,
                isFriendsOverlayEnabled: $isFriendsOverlayEnabled
            )
        }
        .navigationSplitViewStyle(.balanced)
    }
}

#Preview {
    IPadOperationalWorkspaceView()
        .environmentObject(AppViewModel.shared)
}
