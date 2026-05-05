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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if !cardDaySections.isEmpty {
                    ForEach(cardDaySections) { section in
                        Text(section.label)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(dateHeaderTextColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(dayHeaderBackground)

                        ForEach(section.cards, content: timelineCardRow)
                    }
                } else if !daySections.isEmpty {
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
                } else {
                    Text("No shared timeline data for \(friend.employeeID).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
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

    private var cardDaySections: [FriendTimelineCardDaySection] {
        FriendTimelineSectionBuilder.build(from: friend.sharedTimelineCards)
    }

    @ViewBuilder
    private func timelineCardRow(_ card: WebTimelineCard) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: iconName(for: card))
                .foregroundStyle(iconColor(for: card))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(card.title)
                        .font(.subheadline.weight(.bold))
                    Spacer()
                    if let trailing = card.trailing {
                        Text(trailing)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    } else if let timeRange = card.timeRange {
                        Text(timeRange)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(alignment: .firstTextBaseline) {
                    if let subtitle = card.subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let detail = card.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if card.type == "layover", let hotelName = card.hotelName {
                    Text(hotelName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        Divider()
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

    private func iconName(for card: WebTimelineCard) -> String {
        switch card.icon {
        case "hotel":
            return "bed.double.fill"
        case "paperplane":
            return "paperplane.fill"
        default:
            return "airplane"
        }
    }

    private func iconColor(for card: WebTimelineCard) -> Color {
        card.iconTone == "amber" ? .orange : .primary
    }
}
