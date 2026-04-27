//
//  ContentView.swift
//  CodeBarPro
//
//  Preview host for the menu content.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var store = UsageStore()

    var body: some View {
        MenuContentView(store: store)
            .frame(width: 380)
    }
}

#Preview {
    ContentView()
}
