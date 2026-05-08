import SwiftUI

struct AdminVerifiedAppUsersSection: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        Section("Verified App Users") {
            Button {
                Task {
                    await viewModel.refreshVerifiedAppUsers()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isLoadingVerifiedAppUsers)

            if viewModel.isLoadingVerifiedAppUsers {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading verified app users...")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let message = viewModel.verifiedAppUsersMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if viewModel.verifiedAppUsers.isEmpty {
                Text("No verified app users loaded.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.verifiedAppUsers) { user in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("GEMS \(user.gemsID)")
                            .font(.subheadline.weight(.semibold))
                        Text("Verified: \(user.verifiedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .task {
            if viewModel.verifiedAppUsers.isEmpty {
                await viewModel.refreshVerifiedAppUsers()
            }
        }
    }
}
