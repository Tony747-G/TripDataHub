import SwiftUI

struct AdminIdentitySection: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        Section("Admin Identity") {
            Text("CloudKit Record Name")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(viewModel.currentCloudKitRecordName ?? "Unavailable")
                .font(.footnote)
                .textSelection(.enabled)
            Button("Refresh Apple Identity") {
                viewModel.refreshCloudKitIdentity()
            }
        }
    }
}

struct AdminSeniorityImportSection: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let onTapImportCSV: () -> Void
    @State private var isShowingResetConfirmation = false

    var body: some View {
        Section("Seniority Import") {
            Text("Seniority Records: \(viewModel.seniorityCount)")
                .font(.footnote)
            Button("Import Seniority CSV") {
                onTapImportCSV()
            }
            Button("Import from App Documents") {
                viewModel.importSeniorityCSVFromDocuments()
            }
            Button("Reset Seniority DB", role: .destructive) {
                isShowingResetConfirmation = true
            }
            if let message = viewModel.seniorityImportMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .alert("Reset Seniority DB?", isPresented: $isShowingResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                viewModel.resetSeniorityDatabase()
            }
        } message: {
            Text("This deletes imported seniority data on this device. You can re-import the CSV anytime.")
        }
    }
}

struct AdminPendingApprovalSection: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        Section("Pending Approval") {
            if viewModel.pendingFriendConnections.isEmpty {
                Text("No pending friend requests.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.pendingFriendConnections) { friend in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(friend.employeeID)
                            .font(.headline)
                        Text("Requested: \(friend.requestedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button("Approve") {
                                viewModel.approvePseudoFriendRequest(friend.id)
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Reject") {
                                viewModel.rejectPseudoFriendRequest(friend.id)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

struct AdminVerifiedUsersSection: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        Section("Verified Users") {
            if viewModel.verifiedUsers.isEmpty {
                Text("No verified users yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.verifiedUsers) { user in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(user.name)  (GEMS \(user.gemsID))")
                            .font(.subheadline.weight(.semibold))
                        Text("\(user.domicile)  \(user.equipment)  \(user.seat)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Verified: \(user.verifiedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}
