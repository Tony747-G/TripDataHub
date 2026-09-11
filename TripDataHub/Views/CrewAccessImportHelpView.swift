import SwiftUI

/// Production import guidance. It describes only what the pilot does and sees: open the trip, wait
/// for the import, review the preview. How the trip is captured is an implementation detail and is
/// deliberately absent — the legacy Safari / share-sheet / pop-up instructions this replaced
/// described a flow the app no longer uses.
struct CrewAccessImportHelpView: View {
    var body: some View {
        List {
            Section("Importing a Trip") {
                Text("1. Open CrewAccess in TripDataHub.")
                Text("2. Open the trip and display its Details.")
                Text("3. TripDataHub automatically starts the import. Keep the browser open while “Importing Trip…” is shown.")
                Text("4. When Import Preview appears, verify the trip and tap Import.")
            }

            Section("If Import Fails") {
                Text("If “Unable to Import Trip” appears, make sure you have a stable network connection and tap Try Again.")
                Text("If the problem continues, return to CrewAccess and reopen the trip before trying again.")
            }

            Section("Reset the In-App Browser") {
                Text("Use Reset Browser (the eraser icon at the top right) if CrewAccess or Zscaler becomes stuck, shows a blank page, or repeatedly fails to load.")
                Text("Reset clears the in-app browser session and reloads CrewAccess. You may need to sign in again.")
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
