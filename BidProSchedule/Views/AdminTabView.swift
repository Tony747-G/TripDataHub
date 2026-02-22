import SwiftUI
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

struct AdminTabView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var isShowingSeniorityImporter = false

    var body: some View {
        NavigationStack {
            List {
                AdminIdentitySection()
                AdminSeniorityImportSection {
                    isShowingSeniorityImporter = true
                }
                AdminPendingApprovalSection()
                AdminVerifiedUsersSection()
            }
#if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
#endif
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Spacer()
                    Text("Admin")
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
#if canImport(UniformTypeIdentifiers)
            .fileImporter(
                isPresented: $isShowingSeniorityImporter,
                allowedContentTypes: [.commaSeparatedText, .plainText],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case let .success(urls):
                    guard let url = urls.first else { return }
                    guard url.startAccessingSecurityScopedResource() else {
                        viewModel.seniorityImportMessage = "Cannot access selected file."
                        return
                    }
                    defer { url.stopAccessingSecurityScopedResource() }
                    do {
                        let data = try Data(contentsOf: url)
                        viewModel.importSeniorityCSVData(data)
                    } catch {
                        viewModel.seniorityImportMessage = "Failed to load CSV: \(error.localizedDescription)"
                    }
                case let .failure(error):
                    viewModel.seniorityImportMessage = "Import canceled: \(error.localizedDescription)"
                }
            }
#endif
        }
    }
}
