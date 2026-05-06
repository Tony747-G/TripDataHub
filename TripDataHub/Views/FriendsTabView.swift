import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct FriendsTabView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var employeeIDInput = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Friends") {
                    if viewModel.acceptedFriendConnections.isEmpty {
                        Text("No friends yet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.acceptedFriendConnections) { friend in
                            NavigationLink {
                                FriendTimelineView(friend: friend)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(friend.employeeID)
                                        .font(.headline)
                                    if let linkedAt = friend.linkedAt {
                                        Text("Linked: \(linkedAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Add Friend") {
                    TextField("GEMS ID", text: $employeeIDInput)
                        .keyboardType(.numberPad)
                        .textContentType(.username)
                        .submitLabel(.done)
                        .onSubmit(sendFriendRequest)
                    Button("Send Request") {
                        sendFriendRequest()
                    }
                    .disabled(!viewModel.canSubmitFriendRequest)
                    if let message = viewModel.cloudKitIdentityMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !viewModel.isIdentityVerified {
                        Text("Verify your GEMS ID in Settings before adding friends.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if viewModel.isSyncingFriendCloudKit || viewModel.friendCloudKitSyncMessage != nil {
                    Section("CloudKit") {
                        if viewModel.isSyncingFriendCloudKit {
                            ProgressView()
                        }
                        if let message = viewModel.friendCloudKitSyncMessage {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Pending Requests") {
                    if viewModel.pendingFriendConnections.isEmpty {
                        Text("No pending requests.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.pendingFriendConnections) { friend in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(friend.employeeID)
                                    .font(.headline)
                                Text("Requested: \(friend.requestedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Waiting for mutual approval")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                Text("Ask this pilot to add your GEMS ID.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task {
                                        await viewModel.cancelPendingFriendRequest(friend.id)
                                    }
                                } label: {
                                    Label("Cancel", systemImage: "xmark.circle")
                                }
                            }
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
#if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
#endif
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Spacer()
                    Text("Friends")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.vertical, 8)
                .background(.background)
            }
            .onAppear {
                Task {
                    await viewModel.loadSeniorityRecordsIfNeeded()
                    await viewModel.syncFriendCloudKit(reason: "friends opened")
                }
            }
            .alert("Friends", isPresented: friendMessageBinding) {
                Button("OK") {
                    viewModel.friendActionMessage = nil
                }
            } message: {
                Text(viewModel.friendActionMessage ?? "")
            }
        }
    }

    private var friendMessageBinding: Binding<Bool> {
        Binding(
            get: { viewModel.friendActionMessage != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.friendActionMessage = nil
                }
            }
        )
    }

    private func sendFriendRequest() {
        dismissKeyboard()
        let employeeID = employeeIDInput
        employeeIDInput = ""
        Task {
            await viewModel.submitFriendRequest(employeeID: employeeID)
        }
    }

    private func dismissKeyboard() {
#if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
#endif
    }
}

struct FriendTimelineView: View {
    let friend: FriendConnection

    var body: some View {
        ScheduleTimelineRendererView(
            schedules: friend.sharedSchedules,
            emptyStateMessage: "No shared timeline data for \(friend.employeeID)."
        )
        .navigationTitle("\(friend.employeeID) Timeline")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
}
