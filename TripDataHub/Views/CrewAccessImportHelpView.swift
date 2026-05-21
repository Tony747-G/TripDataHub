import SwiftUI

struct CrewAccessImportHelpView: View {
    var body: some View {
        List {
            Section("CrewAccess Import Steps") {
                Text("1. Tap the Browser tab at the bottom of the screen. If CrewAccess shows Bad Request or HTTP 500, tap the reset button in the top-right, then sign in again.")
                Text("2. Log in to CrewAccess.")
                Text("3. Tap the hamburger menu (≡) at the top-left.")
                Text("4. Tap Roster.")
                Text("5. Tap a Trip Id link, or expand a trip and tap Detail.")
                Text("6. When the print preview appears, tap the Zscaler icon at the bottom-right.")
                Text("7. Tap the hamburger menu (≡) at the top-right of the Zscaler sheet.")
                Text("8. Tap Print.")
                Text("9. Tap the Print button, then share the generated PDF to TripData if you are in Safari.")
                Text("10. When Import Preview appears, verify the Trip Id and legs, then tap Confirm Import.")
            }
            Section("Reset the In-App Browser") {
                Text("Use the reset button when CrewAccess or Zscaler gets stuck on Bad Request, HTTP 500, or a blank Print action.")
                Text("Reset clears the in-app browser cookies and cache, closes the print preview, and reloads CrewAccess from a clean session.")
                Text("After reset, sign in again before using Zscaler Print.")
            }
            Section("If Zscaler Print Does Nothing") {
                Text("1. Open iOS Settings > Safari and turn off Block Pop-ups.")
                Text("2. In Safari, leave Private Browsing and use a normal tab.")
                Text("3. Force-close Safari, reopen CrewAccess, and sign in again.")
                Text("4. If Print still does not open, open Settings > Safari > Advanced > Website Data and remove data for ups.com and zscaler.net, then sign in again.")
                Text("5. After the PDF preview opens, use the iOS share button and choose TripData.")
            }
            Section("Importing from Safari") {
                Text("After Zscaler Print opens the PDF preview in Safari, tap the iOS share button and choose TripDataHub.")
                Text("If TripDataHub is not visible, scroll the share sheet, tap More, then enable or select TripDataHub.")
                Text("Only share from the PDF preview. Sharing the normal CrewAccess page sends a web link instead of the schedule PDF.")
            }
            Section("If the Default Browser Shows HTTP 500") {
                Text("1. Return to TripData and use the Safari button again. It opens a Safari view inside TripData instead of Chrome, Edge, or another default browser.")
                Text("2. If the error persists, open the real Safari app manually and go to https://fltops-portal.ups.com/.")
                Text("3. You can also temporarily set Safari as the default browser in iOS Settings > Safari > Default Browser App.")
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
