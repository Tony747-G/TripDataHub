import SwiftUI

struct CrewAccessImportHelpView: View {
    var body: some View {
        List {
            Section("CrewAccess Import Steps") {
                Text("1. Tap the Browser tab at the bottom of the screen.")
                Text("2. Log in to CrewAccess.")
                Text("3. Tap the hamburger menu (≡) at the top-left.")
                Text("4. Tap Roster.")
                Text("5. Tap a Trip Id link, or expand a trip and tap Detail.")
                Text("6. When the print preview appears, tap the Zscaler icon at the bottom-right.")
                Text("7. Tap the hamburger menu (≡) at the top-right of the Zscaler sheet.")
                Text("8. Tap Print.")
                Text("9. Tap the Print button.")
                Text("10. When Import Preview appears, verify the Trip Id and legs, then tap Confirm Import.")
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
