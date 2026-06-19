import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ProfileTabView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ProfileStorageKeys.avatarImageData) private var avatarImageData = Data()
    @AppStorage(ProfileStorageKeys.displayName) private var displayName = ""
    @AppStorage(ProfileStorageKeys.gemsID) private var gemsID = ""
    @AppStorage(ProfileStorageKeys.fleet) private var fleetRawValue = ProfileFleet.fleet757.rawValue
    @AppStorage(OperationalSettings.crewBaseKey) private var baseRawValue = OperationalSettings.defaultCrewBase.rawValue
    @AppStorage("pilot_qualification") private var qualificationRawValue = PilotQualification.captain.rawValue
    @AppStorage(ProfileStorageKeys.lastSeenAt) private var lastSeenAt = 0.0
    @AppStorage(AppViewModel.lastTripSyncCompletedAtKey) private var lastTripSyncCompletedAt = 0.0
    @State private var isShowingAvatarEditor = false
    @State private var verifyDOBDate = Date()
    @State private var isShowingDeleteAccountConfirmation = false
    @State private var isDeletingAccount = false
    let showsCloseButton: Bool

    init(showsCloseButton: Bool = false) {
        self.showsCloseButton = showsCloseButton
    }

    private var fleetBinding: Binding<ProfileFleet> {
        Binding(
            get: { ProfileFleet(rawValue: fleetRawValue) ?? .fleet757 },
            set: { fleetRawValue = $0.rawValue }
        )
    }

    private var baseBinding: Binding<ProfileBase> {
        Binding(
            get: { ProfileBase(rawValue: baseRawValue) ?? .anc },
            set: { baseRawValue = $0.rawValue }
        )
    }

    private var positionBinding: Binding<ProfilePosition> {
        Binding(
            get: {
                switch PilotQualification(rawValue: qualificationRawValue) ?? .captain {
                case .captain:
                    return .ca
                case .firstOfficer:
                    return .fo
                }
            },
            set: { position in
                qualificationRawValue = position == .ca
                    ? PilotQualification.captain.rawValue
                    : PilotQualification.firstOfficer.rawValue
            }
        )
    }

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleGemsID: String {
        viewModel.verifiedIdentity?.gemsID ?? gemsID
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 8) {
                        if !viewModel.isIdentityVerified {
                            Text("Create Account")
                                .font(.headline.weight(.semibold))
                        }

                        avatarPicker

                        profileIdentityRows

                        operationalProfileContent

                        gemsVerificationContent
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Section {
                    profileTimestampRow(title: "Last Seen", value: lastSeenText)
                    profileTimestampRow(
                        title: "Last Trip Sync",
                        value: lastTripSyncText,
                        isInProgress: viewModel.isTripSyncing
                    )
                }

                Section {
                    Button(role: .destructive) {
                        isShowingDeleteAccountConfirmation = true
                    } label: {
                        Text("Delete Account")
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .top, spacing: 0) {
                ZStack {
                    Text("Profile")
                        .font(.headline.weight(.semibold))

                    if showsCloseButton {
                        HStack {
                            Spacer()
                            Button {
                                dismiss()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, height: 34)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Close Profile")
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.background)
            }
            .onAppear {
                seedFromVerifiedIdentityIfNeeded()
                repairSwappedIdentityFieldsIfNeeded()
                recordLastSeen()
            }
            .onDisappear {
                // Upload any edits made during this session.
                guard !isDeletingAccount else { return }
                Task { await viewModel.uploadProfileToCloudKit() }
            }
            // Per-field changes: stamp updatedAt immediately so the timestamp
            // is accurate even if the app is killed before onDisappear fires.
            // The CloudKit upload itself is batched to onDisappear to avoid
            // per-keystroke network calls while the user is still typing.
            .onChange(of: displayName) { _, _ in markProfileUpdatedIfNeeded() }
            .onChange(of: fleetRawValue) { _, _ in markProfileUpdatedIfNeeded() }
            .onChange(of: baseRawValue) { _, _ in markProfileUpdatedIfNeeded() }
            .onChange(of: qualificationRawValue) { _, _ in markProfileUpdatedIfNeeded() }
            .onChange(of: avatarImageData) { _, _ in markProfileUpdatedIfNeeded() }
            .alert("Delete Account?", isPresented: $isShowingDeleteAccountConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete Account", role: .destructive) {
                    deleteAccount()
                }
            } message: {
                Text("This clears the local Profile and GEMS verification on this device. Imported schedules are not deleted.")
            }
#if canImport(UIKit)
            .sheet(isPresented: $isShowingAvatarEditor) {
                ProfileAvatarImagePicker(imageData: $avatarImageData)
            }
#endif
        }
    }

    private var avatarPicker: some View {
        Button {
#if canImport(UIKit)
            isShowingAvatarEditor = true
#endif
        } label: {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.14))
                    .frame(width: 108, height: 108)

                if let image = avatarImage {
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: 108, height: 108)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .accessibilityLabel("Edit Profile Picture")
        }
        .buttonStyle(.plain)
    }

    private var avatarImage: Image? {
#if canImport(UIKit)
        guard let uiImage = UIImage(data: avatarImageData) else { return nil }
        return Image(uiImage: uiImage)
#else
        return nil
#endif
    }

    private var lastSeenText: String {
        guard lastSeenAt > 0 else { return "Never" }
        return Self.lastSeenFormatter.string(from: Date(timeIntervalSince1970: lastSeenAt))
    }

    private var lastTripSyncText: String {
        guard lastTripSyncCompletedAt > 0 else { return "Never" }
        return Self.lastSeenFormatter.string(from: Date(timeIntervalSince1970: lastTripSyncCompletedAt))
    }

    private func profileTimestampRow(title: String, value: String, isInProgress: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
            Spacer()
            if isInProgress {
                ProgressView()
                    .controlSize(.small)
            }
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.9)
        }
    }

    private var profileIdentityRows: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Name:")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 92, alignment: .trailing)

                TextField("Enter your name", text: $displayName)
                    .font(.body.weight(.semibold))
                    .textInputAutocapitalization(.words)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.plain)
                    .frame(width: 190)

                Spacer(minLength: 0)
            }
            .frame(height: 28)
            .padding(.leading, 20)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("GEMS ID:")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: 92, alignment: .trailing)

                if viewModel.isIdentityVerified {
                    Text(visibleGemsID)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(width: 190, alignment: .center)
                } else {
                    TextField("Enter GEMS ID", text: $gemsID)
                        .font(.body.weight(.semibold))
                        .keyboardType(.numberPad)
                        .textContentType(.username)
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.plain)
                        .frame(width: 190)
                        .submitLabel(.done)
                        .onSubmit(verifyIdentity)
                }

                Spacer(minLength: 0)
            }
            .frame(height: 28)
            .padding(.leading, 20)
        }
    }

    @ViewBuilder
    private var gemsVerificationContent: some View {
        if viewModel.isIdentityVerified {
            if let verifiedAtText {
                Text("Verified at \(verifiedAtText)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
        } else {
            Text("Enter GEMS ID")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)

            DatePicker("DOB", selection: $verifyDOBDate, displayedComponents: .date)

            Button("Validate GEMS ID") {
                verifyIdentity()
            }
            .buttonStyle(.borderedProminent)
            .disabled(gemsID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if let message = viewModel.identityActionMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(message.localizedCaseInsensitiveContains("verified") ? .green : .orange)
            }
        }
    }

    @ViewBuilder
    private var operationalProfileContent: some View {
        if viewModel.isIdentityVerified {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Fleet Pos:")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: 92, alignment: .trailing)

                Text("\(baseBinding.wrappedValue.rawValue) \(fleetBinding.wrappedValue.rawValue) \(positionBinding.wrappedValue.rawValue)")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 190, alignment: .center)

                Spacer(minLength: 0)
            }
            .frame(height: 28)
            .padding(.leading, 20)
        } else {
            Picker("Base", selection: baseBinding) {
                ForEach(ProfileBase.allCases) { base in
                    Text(base.rawValue).tag(base)
                }
            }

            Picker("Fleet", selection: fleetBinding) {
                ForEach(ProfileFleet.allCases) { fleet in
                    Text(fleet.rawValue).tag(fleet)
                }
            }

            Picker("Position", selection: positionBinding) {
                ForEach(ProfilePosition.allCases) { position in
                    Text(position.rawValue).tag(position)
                }
            }
        }
    }

    private var verifiedAtText: String? {
        guard viewModel.isIdentityVerified,
              let verifiedAt = viewModel.verifiedIdentity?.verifiedAt else { return nil }
        return Self.lastSeenFormatter.string(from: verifiedAt)
    }

    private func seedFromVerifiedIdentityIfNeeded() {
        guard let identity = viewModel.verifiedIdentity else { return }
        if trimmedName == identity.gemsID || trimmedName == identity.name || trimmedName.hasPrefix("GEMS ") {
            displayName = ""
        }
        if viewModel.isIdentityVerified {
            gemsID = identity.gemsID
        }
        if ProfileFleet(rawValue: fleetRawValue) == nil {
            fleetRawValue = ProfileFleet(rawValue: identity.equipment)?.rawValue ?? ProfileFleet.fleet757.rawValue
        }
        if ProfileBase(rawValue: baseRawValue) == nil {
            baseRawValue = ProfileBase(rawValue: identity.domicile)?.rawValue ?? ProfileBase.anc.rawValue
        }
        if PilotQualification(rawValue: qualificationRawValue) == nil {
            qualificationRawValue = ProfilePosition(rawValue: identity.seat) == .fo
                ? PilotQualification.firstOfficer.rawValue
                : PilotQualification.captain.rawValue
        }
    }

    private func deleteAccount() {
        isDeletingAccount = true
        viewModel.deleteLocalProfileAccount()
        avatarImageData = Data()
        displayName = ""
        gemsID = ""
        fleetRawValue = ProfileFleet.fleet757.rawValue
        baseRawValue = ProfileBase.anc.rawValue
        qualificationRawValue = PilotQualification.captain.rawValue
        isShowingAvatarEditor = false
        dismiss()
    }

    private func verifyIdentity() {
        dismissKeyboard()
        repairSwappedIdentityFieldsIfNeeded()
        Task {
            await viewModel.verifyIdentity(
                gemsID: gemsID,
                dateOfBirth: Self.dobText(from: verifyDOBDate)
            )
        }
    }

    private func repairSwappedIdentityFieldsIfNeeded() {
        guard !viewModel.isIdentityVerified else { return }
        let repaired = ProfileIdentityInput(
            displayName: displayName,
            gemsID: gemsID
        ).repairingClearlySwappedFields()
        guard repaired.displayName != displayName || repaired.gemsID != gemsID else { return }
        displayName = repaired.displayName
        gemsID = repaired.gemsID
    }

    private func markProfileUpdatedIfNeeded() {
        guard !isDeletingAccount else { return }
        viewModel.markProfileUpdated()
    }

    private func dismissKeyboard() {
#if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
#endif
    }

    private func recordLastSeen() {
        lastSeenAt = Date().timeIntervalSince1970
    }

    private static let lastSeenFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd-yyyy HH:mm"
        return formatter
    }()

    private static func dobText(from date: Date) -> String {
        let components = Calendar.current.dateComponents([.month, .day, .year], from: date)
        return String(
            format: "%02d/%02d/%04d",
            components.month ?? 1,
            components.day ?? 1,
            components.year ?? 1900
        )
    }
}

#if canImport(UIKit)
private struct ProfileAvatarImagePicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    @Binding var imageData: Data

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.allowsEditing = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(imageData: $imageData, dismiss: dismiss)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let imageData: Binding<Data>
        private let dismiss: DismissAction

        init(imageData: Binding<Data>, dismiss: DismissAction) {
            self.imageData = imageData
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
            if let image, let data = image.normalizedProfileJPEGData() {
                imageData.wrappedValue = data
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}

private extension UIImage {
    func normalizedProfileJPEGData() -> Data? {
        let side = min(size.width, size.height)
        let origin = CGPoint(
            x: max((size.width - side) / 2, 0),
            y: max((size.height - side) / 2, 0)
        )
        let cropRect = CGRect(origin: origin, size: CGSize(width: side, height: side))
        guard let cgImage = cgImage?.cropping(to: cropRect) else {
            return jpegData(compressionQuality: 0.82)
        }

        let cropped = UIImage(cgImage: cgImage, scale: scale, orientation: imageOrientation)
        let targetSize = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let rendered = renderer.image { _ in
            cropped.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return rendered.jpegData(compressionQuality: 0.82)
    }
}
#endif
