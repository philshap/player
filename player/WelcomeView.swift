//
//  WelcomeView.swift
//  player
//

import SwiftUI
import UniformTypeIdentifiers

/// Shown on first launch or when no library folder bookmark is available.
/// Lets the user create a new portable library, open an existing one, or migrate from a legacy library.
struct WelcomeView: View {
    @Environment(AppState.self) private var appState

    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showNewLibraryPanel = false
    @State private var showOpenLibraryPanel = false
    @State private var showMigratePanel = false
    @State private var isMigrating = false

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

            // Show migration option if an old-style library is detected
            if appState.hasOldLibrary {
                Divider()
                    .frame(maxWidth: 320)

                VStack(spacing: 8) {
                    Text("Previous library detected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button {
                        showMigratePanel = true
                    } label: {
                        Label("Migrate Existing Library…", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isMigrating)
                    .fileImporter(
                        isPresented: $showMigratePanel,
                        allowedContentTypes: [.folder]
                    ) { result in
                        handleMigration(result: result)
                    }

                    if isMigrating {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Migrating library…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
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

    private func handleMigration(result: Result<URL, Error>) {
        do {
            let folderURL = try result.get()
            isMigrating = true
            Task {
                do {
                    try await appState.migrateOldLibrary(to: folderURL)
                } catch {
                    await MainActor.run {
                        errorMessage = error.localizedDescription
                        showError = true
                        isMigrating = false
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
