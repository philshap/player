//
//  WelcomeView.swift
//  player
//

import SwiftUI
import UniformTypeIdentifiers

/// Shown on first launch or when no library folder bookmark is available.
struct WelcomeView: View {
    @Environment(AppState.self) private var appState

    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showNewLibraryPanel = false
    @State private var showOpenLibraryPanel = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "music.note.house")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)

                Text("DJ Player")
                    .font(.largeTitle)
                    .fontWeight(.semibold)

                Text("Choose a library folder to get started.\nThe folder holds your music files and database — perfect for a USB drive.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            HStack(spacing: 16) {
                Button {
                    showNewLibraryPanel = true
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "folder.badge.plus")
                            .font(.title2)
                        Text("New Library…")
                            .fontWeight(.medium)
                    }
                    .frame(width: 140, height: 70)
                }
                .buttonStyle(.borderedProminent)
                .fileImporter(
                    isPresented: $showNewLibraryPanel,
                    allowedContentTypes: [.folder]
                ) { result in
                    handleNewLibrary(result: result)
                }

                Button {
                    showOpenLibraryPanel = true
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.title2)
                        Text("Open Library…")
                            .fontWeight(.medium)
                    }
                    .frame(width: 140, height: 70)
                }
                .buttonStyle(.bordered)
                .fileImporter(
                    isPresented: $showOpenLibraryPanel,
                    allowedContentTypes: [.folder]
                ) { result in
                    handleOpenLibrary(result: result)
                }
            }

            Spacer()
        }
        .padding(40)
        .frame(minWidth: 520, minHeight: 400)
        .alert("Library Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            if let errorMessage {
                Text(errorMessage)
            }
        }
    }

    private func handleNewLibrary(result: Result<URL, Error>) {
        do {
            let folderURL = try result.get()
            try appState.createNewLibrary(at: folderURL)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func handleOpenLibrary(result: Result<URL, Error>) {
        do {
            let folderURL = try result.get()
            try appState.openExistingLibrary(at: folderURL)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
