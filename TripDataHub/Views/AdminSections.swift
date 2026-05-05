import SwiftUI

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
