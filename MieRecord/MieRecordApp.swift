//
//  MieRecordApp.swift
//  MieRecord
//

import SwiftUI

@main
struct MieRecordApp: App {
    @State private var dependencies = AppDependencies.live()

    var body: some Scene {
        WindowGroup {
            RecordingListView()
                .environment(dependencies)
        }
    }
}
