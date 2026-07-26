import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct FriendsTabView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var employeeIDInput = ""
    @State private var editingFriend: FriendConnection?
    @State private var friendPendingRemoval: FriendConnection?
    @State private var nicknameInput = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(sharingStatus.color)
                            .frame(width: 9, height: 9)
                        Text(sharingStatus.text)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if viewModel.isSyncingFriendCloudKit {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                }

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
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    FriendScheduleStatusDot(
                                        health: viewModel.scheduleSyncHealth(for: friend)
                                    )
                                    VStack(alignment: .leading, spacing: 4) {
                                        if let nickname = friend.nickname,
                                           !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            Text("\(nickname)  (\(friend.employeeID))")
                                                .font(.headline)
                                        } else {
                                            Text(friend.employeeID)
                                                .font(.headline)
                                        }
                                        if let updatedAt = friend.sharedSchedules.map(\.updatedAt).max() {
                                            Text("Last Updated: \(updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        } else if let linkedAt = friend.linkedAt {
                                            Text("Linked: \(linkedAt.formatted(date: .abbreviated, time: .shortened))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .simultaneousGesture(
                                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                                    editingFriend = friend
                                    nicknameInput = friend.nickname ?? ""
                                }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    friendPendingRemoval = friend
                                } label: {
                                    Label("Unfriend", systemImage: "person.crop.circle.badge.xmark")
                                }
                            }
                        }
                    }
                }

                Section("Friend Requests") {
                    if viewModel.incomingFriendRequestConnections.isEmpty {
                        Text("No friend requests.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.incomingFriendRequestConnections) { friend in
                            VStack(alignment: .leading, spacing: 8) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(friend.employeeID)
                                        .font(.headline)
                                    Text("Requested: \(friend.requestedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("Waiting for your approval")
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                    Text("This pilot added your GEMS ID.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Button {
                                    Task {
                                        await viewModel.acceptIncomingFriendRequest(friend.id)
                                    }
                                } label: {
                                    Label("Accept Request", systemImage: "checkmark.circle.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                            .padding(.vertical, 2)
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
            .alert("Rename Friend", isPresented: Binding(
                get: { editingFriend != nil },
                set: { if !$0 { editingFriend = nil } }
            )) {
                TextField("Nickname (leave blank to reset)", text: $nicknameInput)
                Button("Save") {
                    if let friend = editingFriend {
                        viewModel.setFriendNickname(id: friend.id, nickname: nicknameInput)
                    }
                    editingFriend = nil
                }
                Button("Cancel", role: .cancel) { editingFriend = nil }
            } message: {
                if let friend = editingFriend {
                    Text("GEMS: \(friend.employeeID)")
                }
            }
            .confirmationDialog(
                friendPendingRemoval.map { "Unfriend \($0.displayName)?" } ?? "Unfriend?",
                isPresented: Binding(
                    get: { friendPendingRemoval != nil },
                    set: { if !$0 { friendPendingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Unfriend", role: .destructive) {
                    if let friend = friendPendingRemoval {
                        Task {
                            await viewModel.removeFriend(friend.id)
                        }
                    }
                    friendPendingRemoval = nil
                }
                Button("Cancel", role: .cancel) {
                    friendPendingRemoval = nil
                }
            } message: {
                if let friend = friendPendingRemoval {
                    Text("This removes \(friend.displayName) from Friends and stops sharing schedules with this pilot.")
                }
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

    private var sharingStatus: (color: Color, text: String) {
        if !viewModel.isIdentityVerified {
            return (.gray, "Schedule sharing off")
        }
        if let message = viewModel.friendCloudKitSyncMessage,
           message.hasPrefix("Failed") {
            return (.red, "Schedule sharing needs attention")
        }
        if viewModel.isSyncingFriendCloudKit {
            return (.orange, "Updating schedule sharing")
        }
        if !viewModel.acceptedFriendConnections.isEmpty {
            return (.green, "Schedule sharing active")
        }
        if !viewModel.pendingFriendConnections.isEmpty {
            return (.gray, "Mutual approval needed")
        }
        if viewModel.isScheduleSharingEnabled {
            return (.gray, "Schedule sharing on")
        }
        return (.gray, "Schedule sharing off")
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
        .navigationTitle("\(friend.displayName) Timeline")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
}
