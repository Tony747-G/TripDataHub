import SwiftUI

struct CrewAccessImportHelpView: View {
    var body: some View {
        List {
            Section("Correct PDF Export Method") {
                Text("1. Open the CrewAccess schedule page.")
                Text("2. Click Zscaler Print (do NOT use browser print).")
                Text("3. Choose “Print Schedule”.")
                Text("4. Save as PDF.")
                Text("5. Verify text is selectable by long-pressing text in the PDF.")
                Text("6. Open the PDF in TripData Hub.")
            }

            Section("If Import Fails:") {
                Text("This PDF was flattened into an image.")
                Text("Re-export using Zscaler Print. Screenshots or scans will not work.")
            }

            Section("What the App Uses") {
                Text("Times are stored in UTC internally.")
                Text("Local display times are derived from airport time zones.")
                Text("This prevents DST and cross-day confusion.")
            }
        }
        .navigationTitle("CrewAccess Import Help")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
}

#Preview {
    NavigationStack {
        CrewAccessImportHelpView()
    }
}
