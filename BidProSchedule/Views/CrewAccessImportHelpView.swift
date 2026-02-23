import SwiftUI

struct CrewAccessImportHelpView: View {
    var body: some View {
        List {
            Section("CrewAccess Import Steps") {
                Text("1. Open CrewAccess and go to the Roster page.")
                Text("2. Tap the expand arrow on the right side of the trip you want to import.")
                Text("3. Tap Details, then tap Allow when prompted.")
                Text("4. Tap the Zscaler logo at the bottom-right.")
                Text("5. Tap the menu (3 lines) at the top-right.")
                Text("6. Tap Print, then tap Allow when prompted again.")
                Text("7. In the print view, tap the Share icon (left of the printer icon).")
                Text("8. In the Share Sheet, tap TripData Hub (it may be under More).")
                Text("9. In TripData Hub, tap Confirm Import.")
            }

            Section("If Import Fails:") {
                Text("1. Save the trip PDF to your device.")
                Text("2. In TripData Hub, tap Import CrewAccess PDF manually.")
                Text("3. Select the saved PDF and tap Confirm Import.")
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
