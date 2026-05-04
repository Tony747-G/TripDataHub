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
        Section("GEMS Verification Import") {
            Text("Verification Records Uploaded: \(viewModel.seniorityCount)")
                .font(.footnote)
            Button("Upload GEMS/DOB CSV") {
                onTapImportCSV()
            }
            .disabled(viewModel.isUploadingGEMSVerification)
            Button("Import from App Documents") {
                Task {
                    await viewModel.importSeniorityCSVFromDocuments()
                }
            }
            .disabled(viewModel.isUploadingGEMSVerification)
            Button("Reset Seniority DB", role: .destructive) {
                isShowingResetConfirmation = true
            }
            .disabled(viewModel.isUploadingGEMSVerification)
            if viewModel.isUploadingGEMSVerification {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Uploading verification records...")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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
            Text("This deletes legacy local seniority data on this device. CloudKit verification records are not deleted.")
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
