//
//  DashCamClips.swift
//  DashCam
//
//  Created by Muhanned Alkhafaji on 3/1/26.
//

import SwiftUI
import AVKit
import Combine
import UIKit

// clip browser

// move all clip list and player code out of the main dashcam file first

// this is one of the safest splits because it does not touch the camera session or recording pipeline

// clips screen

// this screen shows every saved movie and snapshot inside the dashcam clips folder

// users can refresh the list, tap into a viewer, or delete media from here

struct DashCamClipsView: View {
    
    // dismiss
    
    // this closes the clips sheet and returns to the camera screen
    
    @Environment(\.dismiss) private var dismiss
    
    // library
    
    // this object loads the folder contents, turns them into clip models, and handles deletion
    
    @StateObject private var library = DashClipLibrary()
    
    var body: some View {
        NavigationStack {
            Group {
                if library.clips.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(library.clips) { clip in
                            // clip row button
                            
                            // tapping a row pushes into the player or photo viewer for that file
                            
                            NavigationLink {
                                DashCamClipPlayerView(clip: clip)
                            } label: {
                                DashCamClipRowView(clip: clip)
                            }
                            .listRowBackground(Color.black.opacity(0.22))
                        }
                        .onDelete(perform: library.delete)
                    }
                    .scrollContentBackground(.hidden)
                    .background(Color.black)
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Clips")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // close button
                    
                    // closes the clips sheet
                    
                    Button("Close") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    // refresh button
                    
                    // re-scans the clips folder in case new files were saved while the sheet was open
                    
                    Button {
                        library.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .onAppear {
                // initial load
                
                // load the clips every time this screen appears so the list stays current
                
                library.reload()
            }
        }
        .preferredColorScheme(.dark)
    }
    
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 42))
                .foregroundStyle(.white.opacity(0.8))
            
            Text("No saved media yet")
                .font(.system(size: 18, weight: .bold, design: .rounded))
            
            Text("Saved videos and rear snapshots will show up here.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

// clip row view

// this is the one line item shown for each saved file in the list

struct DashCamClipRowView: View {
    
    // clip
    
    // the saved file model this row is displaying
    
    let clip: DashClipFile
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: clip.kind == .movie ? "film" : "photo")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.82))

                Text(clip.name)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            
            Text("\(clip.dateText) • \(clip.sizeText)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

// clip player view

// this screen plays one saved clip or shows one saved snapshot with file details

struct DashCamClipPlayerView: View {
    
    // clip
    
    // the selected clip that should be played and shared
    
    let clip: DashClipFile
    
    // player
    
    // this avplayer is created when the screen appears and paused when the screen goes away
    
    @State private var player: AVPlayer?
    @State private var showingShareSheet = false
    
    var body: some View {
        VStack(spacing: 16) {
            if clip.kind == .movie {
                if let player {
                    ClipPlayerContainer(player: player)
                        .frame(maxWidth: .infinity)
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(.white.opacity(0.18), lineWidth: 1)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.black.opacity(0.45))
                        .frame(height: 260)
                        .overlay {
                            ProgressView()
                        }
                }
            } else {
                if let image = UIImage(contentsOfFile: clip.url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .frame(height: 260)
                        .background(.black.opacity(0.45))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(.white.opacity(0.18), lineWidth: 1)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.black.opacity(0.45))
                        .frame(height: 260)
                        .overlay {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.white.opacity(0.75))
                        }
                }
            }
            
            VStack(spacing: 10) {
                infoRow("file", value: clip.name)
                infoRow("date", value: clip.dateText)
                infoRow("size", value: clip.sizeText)
                infoRow("path", value: clip.url.lastPathComponent)
            }
            
            Spacer()
        }
        .padding(16)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(clip.kind == .movie ? "Player" : "Photo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // share button
                
                // lets the user export the selected clip using the normal ios share sheet
                
                Button {
                    showingShareSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            ActivityShareSheet(items: [clip.url])
        }
        .onAppear {
            // build player
            
            // create the avplayer only once and start playback immediately
            
            if clip.kind == .movie, player == nil {
                player = AVPlayer(url: clip.url)
            }
            player?.play()
        }
        .onDisappear {
            // pause player
            
            // stop playback when leaving the player screen
            
            player?.pause()
        }
    }
    
    private func infoRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 42, alignment: .leading)
            
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct ClipPlayerContainer: UIViewControllerRepresentable {

    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.view.backgroundColor = .black
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }
}

struct ActivityShareSheet: UIViewControllerRepresentable {

    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
    }
}

// clip file model

// this model describes one saved movie or snapshot file on disk

enum DashClipKind: Hashable {
    case movie
    case photo
}

struct DashClipFile: Identifiable, Hashable {
    
    // url
    
    // full local file url for the saved movie
    
    let url: URL
    
    // date
    
    // the file modification date used for sorting and display
    
    let date: Date
    
    // size
    
    // byte count of the saved media file
    
    let size: Int64

    let kind: DashClipKind
    
    var id: String { url.path }
    
    var name: String {
        url.lastPathComponent
    }
    
    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
    
    var dateText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

// clip library

// this object owns the list of clips and all file system work for the clips screen

final class DashClipLibrary: ObservableObject {
    
    // clips
    
    // the current clip list shown in the ui
    
    @Published var clips: [DashClipFile] = []
    
    func reload() {
        do {
            // clips folder
            
            // ask the dashcam controller for the same folder used by recording so the browser stays in sync
            
            let folderURL = try DashCamController.clipsFolderURL()
            
            // file resource keys
            
            // these are the file attributes we need for filtering, sorting, and display
            
            let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
            let urls = FileManager.default.enumerator(
                at: folderURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            )?.compactMap { $0 as? URL } ?? []
            
            let clipFiles = urls.compactMap { url -> DashClipFile? in
                let fileExtension = url.pathExtension.lowercased()
                let kind: DashClipKind

                switch fileExtension {
                case "mov":
                    kind = .movie
                case "jpg", "jpeg":
                    kind = .photo
                default:
                    return nil
                }

                let values = try? url.resourceValues(forKeys: resourceKeys)
                guard values?.isRegularFile == true else { return nil }
                let date = values?.contentModificationDate ?? .distantPast
                let size = Int64(values?.fileSize ?? 0)
                return DashClipFile(url: url, date: date, size: size, kind: kind)
            }
            .sorted { $0.date > $1.date }
            
            DispatchQueue.main.async {
                self.clips = clipFiles
            }
        } catch {
            DispatchQueue.main.async {
                self.clips = []
            }
        }
    }
    
    func delete(at offsets: IndexSet) {
        // targets
        
        // turn the swipe-to-delete indexes into real clip objects first
        
        let targets = offsets.map { clips[$0] }
        
        for clip in targets {
            try? FileManager.default.removeItem(at: clip.url)
        }
        
        reload()
    }
}
