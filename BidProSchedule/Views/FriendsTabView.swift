import SwiftUI

struct FriendsTabView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var employeeIDInput = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Add Friend") {
                    TextField("GEMS ID", text: $employeeIDInput)
                    Button("Send Request") {
                        viewModel.submitPseudoFriendRequest(employeeID: employeeIDInput)
                        employeeIDInput = ""
                    }
                    .disabled(!viewModel.canSubmitFriendRequest)
                }

                if let message = viewModel.friendActionMessage {
                    Section("Status") {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
                                Text("Waiting for admin approval")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section("Friends") {
                    if viewModel.acceptedFriendConnections.isEmpty {
                        Text("No friends yet. Approve a pending request.")
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
            }
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
                }
            }
        }
    }
}

struct FriendTimelineView: View {
    let friend: FriendConnection
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if daySections.isEmpty {
                    Text("No shared timeline data for \(friend.employeeID).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                } else {
                    ForEach(daySections) { section in
                        Text(section.label)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(dateHeaderTextColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(dayHeaderBackground)

                        ForEach(section.legs) { leg in
                            HStack(alignment: .center, spacing: 12) {
                                Image(systemName: "airplane")
                                    .foregroundStyle(.primary)
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("\(leg.depAirport) - \(leg.arrAirport)")
                                            .font(.subheadline.weight(.bold))
                                        Spacer()
                                        Text(timeRangeText(for: leg))
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    HStack {
                                        Text(leg.displayFlightNumberText)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("Block: \(leg.block)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
            }
        }
        .navigationTitle("\(friend.employeeID) Timeline")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    private var daySections: [FriendTimelineDaySection] {
        FriendTimelineSectionBuilder.build(from: friend.sharedSchedules)
    }

    private func timeRangeText(for leg: TripLeg) -> String {
        let dep = ScheduleDateText.timePart(from: leg.depLocal)
        let arr = ScheduleDateText.timePart(from: leg.arrLocal)
        return "\(dep) - \(arr)"
    }

    private var dayHeaderBackground: Color {
        ScheduleColors.dayHeaderBackground(for: colorScheme)
    }

    private var dateHeaderTextColor: Color {
        ScheduleColors.timelineDateHeaderText(for: colorScheme)
    }
}
