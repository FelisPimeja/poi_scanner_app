//
//  POI_ScannerApp.swift
//  POI Scanner
//
//  Created by Aleksandr Petrov on 18.04.2026.
//

import SwiftUI

@main
struct POI_ScannerApp: App {
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
        }
    }
}
