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
import Photos
import ImageIO

enum DashClipMediaFilter: String, CaseIterable, Identifiable {
    case all
    case videos
    case photos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .videos:
            return "Clips"
        case .photos:
            return "Photos"
        }
    }

    func includes(_ kind: DashClipKind) -> Bool {
        switch self {
        case .all:
            return true
        case .videos:
            return kind.isMovie
        case .photos:
            return kind.isPhoto
        }
    }
}

enum DashClipEventFilter: String, CaseIterable, Identifiable {
    case all
    case protectedClips
    case manualSaves
    case crashEvents
    case routeLinked
    case standard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All events"
        case .protectedClips:
            return "Protected"
        case .manualSaves:
            return "Manual"
        case .crashEvents:
            return "Crash"
        case .routeLinked:
            return "Route"
        case .standard:
            return "Standard"
        }
    }

    func includes(_ clip: DashClipFile) -> Bool {
        let metadata = clip.metadata

        switch self {
        case .all:
            return true
        case .protectedClips:
            return metadata?.isProtected == true
        case .manualSaves:
            return metadata?.contains(.manualSave) == true
        case .crashEvents:
            return metadata?.contains(.crash) == true
        case .routeLinked:
            return metadata?.contains(.routeLinked) == true
        case .standard:
            guard let metadata else { return true }
            return metadata.effectiveTags.isEmpty
        }
    }
}

// clip browser

// move all clip list and player code out of the main dashcam file first

// this is one of the safest splits because it does not touch the camera session or recording pipeline

// clips screen

// this screen shows every saved movie and snapshot inside the dashcam clips folder

// users can refresh the list, tap into a viewer, or delete media from here

struct DashCamClipsView: View {
    let scope: DashClipPresentation
    
    // dismiss
    
    // this closes the clips sheet and returns to the camera screen
    
    @Environment(\.dismiss) private var dismiss
    
    // library
    
    // this object loads the folder contents, turns them into clip models, and handles deletion
    
    @StateObject private var library = DashClipLibrary()
    @State private var showingCalendarPicker = false
    @State private var selectedCalendarDay = Date()
    @State private var activeDayFilter: Date?
    @State private var mediaFilter: DashClipMediaFilter = .all
    @State private var eventFilter: DashClipEventFilter = .all
    @State private var editMode: EditMode = .inactive
    @State private var selectedClipIDs = Set<String>()
    @State private var showingBatchShareSheet = false
    @State private var exportStatusMessage = ""
    @State private var showingExportStatus = false

    private var daySections: [DashClipDaySection] {
        DashClipDaySection.makeSections(from: filteredClips)
    }

    private var filteredClips: [DashClipFile] {
        scopeFilteredClips.filter {
            mediaFilter.includes($0.kind) && eventFilter.includes($0)
        }
    }

    private var scopeFilteredClips: [DashClipFile] {
        switch scope {
        case .library:
            return library.clips
        case .drive(let drive):
            return library.clips.filter { clip in
                let startedAt = clip.metadata?.startedAt ?? clip.date
                let endedAt = clip.metadata?.endedAt ?? clip.date
                return endedAt >= drive.startedAt && startedAt <= drive.endedAt
            }
        }
    }

    private var displayedSections: [DashClipDaySection] {
        guard let activeDayFilter else { return daySections }
        return daySections.filter { Calendar.current.isDate($0.day, inSameDayAs: activeDayFilter) }
    }

    private var selectedClips: [DashClipFile] {
        filteredClips.filter { selectedClipIDs.contains($0.id) }
    }

    private var navigationTitleText: String {
        switch scope {
        case .library:
            return "Clips"
        case .drive:
            return "Drive Clips"
        }
    }

    private var scopeSummaryText: String? {
        switch scope {
        case .library:
            return nil
        case .drive(let drive):
            return "\(drive.titleText) • \(drive.subtitleText)"
        }
    }

    init(scope: DashClipPresentation = .library) {
        self.scope = scope
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let scopeSummaryText {
                    Text(scopeSummaryText)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }

                if !library.clips.isEmpty {
                    VStack(spacing: 8) {
                        mediaFilterPicker
                        eventFilterPicker
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                }

                Group {
                    if library.clips.isEmpty {
                        emptyState
                    } else if displayedSections.isEmpty {
                        filteredEmptyState
                    } else {
                        List(selection: $selectedClipIDs) {
                            ForEach(displayedSections) { section in
                                Section {
                                    ForEach(section.clips) { clip in
                                        NavigationLink {
                                            DashCamClipPlayerView(clip: clip)
                                        } label: {
                                            DashCamClipRowView(clip: clip)
                                        }
                                        .listRowBackground(Color.black.opacity(0.22))
                                    }
                                    .onDelete { offsets in
                                        library.delete(in: section, at: offsets)
                                    }
                                } header: {
                                    daySectionHeader(section)
                                }
                            }
                        }
                        .environment(\.editMode, $editMode)
                        .scrollContentBackground(.hidden)
                        .background(Color.black)
                    }
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(navigationTitleText)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editMode == .active ? "Done" : "Select") {
                        withAnimation(.easeOut(duration: 0.18)) {
                            if editMode == .active {
                                editMode = .inactive
                                selectedClipIDs.removeAll()
                            } else {
                                editMode = .active
                            }
                        }
                    }
                    .disabled(filteredClips.isEmpty)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        selectedCalendarDay = activeDayFilter ?? daySections.first?.day ?? Date()
                        showingCalendarPicker = true
                    } label: {
                        Image(systemName: activeDayFilter == nil ? "calendar" : "calendar.badge.clock")
                    }
                    .disabled(library.clips.isEmpty)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        library.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }

                if editMode == .active {
                    ToolbarItem(placement: .bottomBar) {
                        HStack(spacing: 18) {
                            Button {
                                showingBatchShareSheet = true
                            } label: {
                                Label("Export", systemImage: "square.and.arrow.up")
                            }
                            .disabled(selectedClips.isEmpty)

                            Button {
                                saveSelectedClipsToPhotos()
                            } label: {
                                Label("Save to Photos", systemImage: "photo.on.rectangle")
                            }
                            .disabled(selectedClips.isEmpty)
                        }
                    }
                }
            }
            .onAppear {
                library.reload()
            }
            .sheet(isPresented: $showingCalendarPicker) {
                ClipCalendarFilterView(
                    availableDays: daySections.map(\.day),
                    selectedDay: $selectedCalendarDay,
                    activeDayFilter: $activeDayFilter
                )
            }
            .onChange(of: library.clips) { _, _ in
                guard let activeDayFilter else { return }
                let dayStillExists = daySections.contains { Calendar.current.isDate($0.day, inSameDayAs: activeDayFilter) }
                if !dayStillExists {
                    self.activeDayFilter = nil
                }
            }
            .sheet(isPresented: $showingBatchShareSheet) {
                ActivityShareSheet(items: selectedClips.map(\.url))
            }
            .alert("Export", isPresented: $showingExportStatus) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportStatusMessage)
            }
        }
        .preferredColorScheme(.dark)
    }
    
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 42))
                .foregroundStyle(.white.opacity(0.8))
            
            Text(scopeEmptyTitle)
                .font(.system(size: 18, weight: .bold, design: .rounded))
            
            Text(scopeEmptyMessage)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 42))
                .foregroundStyle(.white.opacity(0.8))

            Text(filteredEmptyTitle)
                .font(.system(size: 18, weight: .bold, design: .rounded))

            Text(filteredEmptyMessage)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 28)

            Button("Show all clips") {
                activeDayFilter = nil
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var scopeEmptyTitle: String {
        switch scope {
        case .library:
            return "No saved media yet"
        case .drive:
            return "No media for this drive"
        }
    }

    private var scopeEmptyMessage: String {
        switch scope {
        case .library:
            return "Saved videos and rear snapshots will show up here."
        case .drive:
            return "This drive does not have any matching clips or photos yet."
        }
    }

    private var mediaFilterPicker: some View {
        Picker("Media type", selection: $mediaFilter) {
            ForEach(DashClipMediaFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.segmented)
    }

    private var eventFilterPicker: some View {
        Picker("Event type", selection: $eventFilter) {
            ForEach(DashClipEventFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var filteredEmptyTitle: String {
        if activeDayFilter != nil {
            switch mediaFilter {
            case .all:
                return "No media on this day"
            case .videos:
                return "No clips on this day"
            case .photos:
                return "No photos on this day"
            }
        }

        switch mediaFilter {
        case .all:
            return "No saved media"
        case .videos:
            return "No saved clips"
        case .photos:
            return "No saved photos"
        }
    }

    private var filteredEmptyMessage: String {
        if activeDayFilter != nil {
            switch mediaFilter {
            case .all:
                return "Pick another day from the calendar or clear the filter to show all saved media."
            case .videos:
                return "This day does not have any saved video clips. Try another day or switch the filter."
            case .photos:
                return "This day does not have any saved photos. Try another day or switch the filter."
            }
        }

        switch mediaFilter {
        case .all:
            return "There is no saved media that matches the current filters."
        case .videos:
            return "There are no saved video clips yet. Switch to Photos or All to see snapshots."
        case .photos:
            return "There are no saved photos yet. Switch to Clips or All to see recordings."
        }
    }

    private func daySectionHeader(_ section: DashClipDaySection) -> some View {
        HStack {
            Text(section.title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Spacer()

            Text(section.countText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
        }
        .textCase(nil)
    }

    private func saveSelectedClipsToPhotos() {
        let clips = selectedClips
        guard !clips.isEmpty else { return }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    exportStatusMessage = "Photo Library access was denied."
                    showingExportStatus = true
                }
                return
            }

            PHPhotoLibrary.shared().performChanges {
                for clip in clips {
                    if clip.kind.isMovie {
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: clip.url)
                    } else if let image = UIImage(contentsOfFile: clip.url.path) {
                        PHAssetChangeRequest.creationRequestForAsset(from: image)
                    }
                }
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    exportStatusMessage = success
                        ? "Saved \(clips.count) item\(clips.count == 1 ? "" : "s") to Photos."
                        : (error?.localizedDescription ?? "Could not save the selected items to Photos.")
                    showingExportStatus = true
                }
            }
        }
    }
}

private struct ClipCalendarFilterView: View {
    let availableDays: [Date]
    @Binding var selectedDay: Date
    @Binding var activeDayFilter: Date?

    @Environment(\.dismiss) private var dismiss

    private var normalizedAvailableDays: [Date] {
        availableDays.sorted(by: >)
    }

    private var dateRange: ClosedRange<Date> {
        let sorted = normalizedAvailableDays
        let fallback = Calendar.current.startOfDay(for: Date())
        let lowerBound = sorted.last ?? fallback
        let upperBound = sorted.first ?? fallback
        return lowerBound...upperBound
    }

    private var selectedDayHasClips: Bool {
        normalizedAvailableDays.contains { Calendar.current.isDate($0, inSameDayAs: selectedDay) }
    }

    private var selectedDayText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: selectedDay)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                DatePicker(
                    "Clip day",
                    selection: $selectedDay,
                    in: dateRange,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
                .tint(.blue)

                VStack(alignment: .leading, spacing: 8) {
                    Text(selectedDayText)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(selectedDayHasClips ? "Show clips saved on this day." : "No saved clips were found on this day.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                }

                Spacer()
            }
            .padding(16)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Pick a Day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Show all") {
                        activeDayFilter = nil
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Show day") {
                        activeDayFilter = Calendar.current.startOfDay(for: selectedDay)
                        dismiss()
                    }
                    .disabled(!selectedDayHasClips)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// clip row view

// this is the one line item shown for each saved file in the list

struct DashCamClipRowView: View {
    
    // clip
    
    // the saved file model this row is displaying
    
    let clip: DashClipFile
    
    var body: some View {
        HStack(spacing: 12) {
            DashClipThumbnailView(clip: clip)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: clip.kind.symbolName)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.82))

                    Text(clip.name)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }

                Text(clip.secondaryLineText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)

                if !clip.displayTagTitles.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(clip.displayTagTitles, id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.white.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct DashClipThumbnailView: View {
    let clip: DashClipFile

    var body: some View {
        Group {
            if let thumbnail = clip.thumbnailImage {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [.white.opacity(0.12), .white.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    Image(systemName: clip.kind.symbolName)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .frame(width: 92, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        )
    }
}

// clip player view

// this screen plays one saved clip or shows one saved snapshot with file details

struct DashCamClipPlayerView: View {
    
    // clip
    
    // the selected clip that should be played and shared
    
    @State private var clip: DashClipFile
    
    // player
    
    // this avplayer is created when the screen appears and paused when the screen goes away
    
    @State private var player: AVPlayer?
    @State private var showingShareSheet = false
    @State private var exportStatusMessage = ""
    @State private var showingExportStatus = false

    init(clip: DashClipFile) {
        _clip = State(initialValue: clip)
    }
    
    var body: some View {
        VStack(spacing: 16) {
            if clip.kind.isMovie {
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
                infoRow("time", value: clip.timestampLine)
                infoRow("size", value: clip.sizeText)
                if let durationText = clip.durationText {
                    infoRow("length", value: durationText)
                }
                if let gpsLine = clip.gpsLine {
                    infoRow("gps", value: gpsLine)
                }
                if let speedLine = clip.speedLine {
                    infoRow("speed", value: speedLine)
                }
                if let headingLine = clip.headingLine {
                    infoRow("heading", value: headingLine)
                }
                if let routeLine = clip.routeLine {
                    infoRow("route", value: routeLine)
                }
                if !clip.displayTagTitles.isEmpty {
                    infoRow("tags", value: clip.displayTagTitles.joined(separator: ", "))
                }
                infoRow("path", value: clip.url.lastPathComponent)
            }
            
            Spacer()
        }
        .padding(16)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(clip.kind.playerTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingShareSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    saveToPhotos()
                } label: {
                    Image(systemName: "photo.on.rectangle")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    toggleProtection()
                } label: {
                    Image(systemName: clip.metadata?.isProtected == true ? "lock.fill" : "lock.open")
                }
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            ActivityShareSheet(items: [clip.url])
        }
        .onAppear {
            // build player
            
            // create the avplayer only once and start playback immediately
            
            if clip.kind.isMovie, player == nil {
                player = AVPlayer(url: clip.url)
            }
            player?.play()
        }
        .onDisappear {
            // pause player
            
            // stop playback when leaving the player screen
            
            player?.pause()
        }
        .alert("Clip", isPresented: $showingExportStatus) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportStatusMessage)
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

    private func toggleProtection() {
        if DashClipMetadataStore.load(for: clip.url) == nil {
            let fallbackSnapshot = DashClipCaptureSnapshot(
                recordedAt: clip.date,
                coordinate: nil,
                speedMetersPerSecond: nil,
                headingDegrees: nil,
                route: nil
            )
            let fallbackMetadata = DashClipMetadata(
                mediaFileName: clip.url.lastPathComponent,
                source: clip.kind.metadataSource,
                startedAt: clip.date,
                endedAt: clip.date,
                recordingMode: nil,
                quality: nil,
                rearLens: nil,
                durationSeconds: clip.durationSeconds,
                captureSnapshot: fallbackSnapshot,
                isProtected: true,
                eventTags: [.protectedClip]
            )
            try? DashClipMetadataStore.save(fallbackMetadata, for: clip.url)
            // The fallback sidecar is created only for a clip the user is
            // actively protecting, so we immediately align its metadata file
            // with the saved-media protection policy.
            try? DashCamController.applySavedMediaProtection(to: clip.url)
        } else {
            DashClipMetadataStore.update(for: clip.url) { metadata in
                if metadata.isProtected {
                    metadata.isProtected = false
                    metadata.eventTags.removeAll { $0 == .protectedClip }
                } else {
                    metadata.add(tags: [.protectedClip], protected: true)
                }
            }
            try? DashCamController.applySavedMediaProtection(to: clip.url)
        }

        clip = clip.reloadingMetadata()
    }

    private func saveToPhotos() {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    exportStatusMessage = "Photo Library access was denied."
                    showingExportStatus = true
                }
                return
            }

            PHPhotoLibrary.shared().performChanges {
                if clip.kind.isMovie {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: clip.url)
                } else if let image = UIImage(contentsOfFile: clip.url.path) {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    exportStatusMessage = success
                        ? "Saved to Photos."
                        : (error?.localizedDescription ?? "Could not save this item to Photos.")
                    showingExportStatus = true
                }
            }
        }
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

    var isMovie: Bool {
        switch self {
        case .movie:
            return true
        case .photo:
            return false
        }
    }

    var isPhoto: Bool {
        !isMovie
    }

    var symbolName: String {
        switch self {
        case .movie:
            return "film"
        case .photo:
            return "photo"
        }
    }

    var playerTitle: String {
        switch self {
        case .movie:
            return "Player"
        case .photo:
            return "Photo"
        }
    }

    var metadataSource: DashClipSource {
        switch self {
        case .movie:
            return .recordingSegment
        case .photo:
            return .snapshotPhoto
        }
    }
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
    let metadata: DashClipMetadata?
    let durationSeconds: Double?
    let thumbnailData: Data?
    
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

    var durationText: String? {
        let seconds = durationSeconds ?? metadata?.durationSeconds
        guard let seconds, seconds > 0 else { return nil }

        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = [.pad]
        return formatter.string(from: seconds)
    }

    var thumbnailImage: UIImage? {
        guard let thumbnailData else { return nil }
        return UIImage(data: thumbnailData)
    }

    var timestampLine: String {
        if let metadata {
            return "\(formatDate(metadata.startedAt))"
        }
        return dateText
    }

    var secondaryLineText: String {
        var parts = [timestampLine]
        if let durationText {
            parts.append(durationText)
        }
        parts.append(sizeText)
        return parts.joined(separator: " • ")
    }

    var displayTagTitles: [String] {
        var tags = [kind.isMovie ? "Video" : "Photo"]
        for tag in metadata?.effectiveTags ?? [] {
            let title = tag.title
            if !tags.contains(title) {
                tags.append(title)
            }
        }
        return tags
    }

    var gpsLine: String? {
        guard let coordinate = metadata?.captureSnapshot.coordinate else { return nil }
        return String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    var speedLine: String? {
        guard let speed = metadata?.captureSnapshot.speedMetersPerSecond else { return nil }
        return String(format: "%.1f mph", max(0, speed * 2.2369362921))
    }

    var headingLine: String? {
        guard let heading = metadata?.captureSnapshot.headingDegrees else { return nil }
        return String(format: "%.0f°", heading)
    }

    var routeLine: String? {
        metadata?.captureSnapshot.route?.line
    }

    func reloadingMetadata() -> DashClipFile {
        DashClipFile(
            url: url,
            date: date,
            size: size,
            kind: kind,
            metadata: DashClipMetadataStore.load(for: url),
            durationSeconds: durationSeconds,
            thumbnailData: thumbnailData
        )
    }

    func applyingPreview(durationSeconds: Double?, thumbnailData: Data?) -> DashClipFile {
        DashClipFile(
            url: url,
            date: date,
            size: size,
            kind: kind,
            metadata: metadata,
            durationSeconds: durationSeconds ?? self.durationSeconds,
            thumbnailData: thumbnailData ?? self.thumbnailData
        )
    }

    private func formatDate(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: value)
    }
}

struct DashClipDaySection: Identifiable, Hashable {
    let day: Date
    let clips: [DashClipFile]

    var id: Date { day }

    var title: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: day)
    }

    var countText: String {
        "\(clips.count) item\(clips.count == 1 ? "" : "s")"
    }

    static func makeSections(from clips: [DashClipFile], calendar: Calendar = .current) -> [DashClipDaySection] {
        let grouped = Dictionary(grouping: clips) { clip in
            calendar.startOfDay(for: clip.date)
        }

        return grouped
            .map { DashClipDaySection(day: $0.key, clips: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }
    }
}

// clip library

// this object owns the list of clips and all file system work for the clips screen

private struct DashClipPreviewCacheEntry {
    let cacheKey: String
    let durationSeconds: Double?
    let thumbnailData: Data?
}

private actor DashClipPreviewCache {
    static let shared = DashClipPreviewCache()

    private var entries: [String: DashClipPreviewCacheEntry] = [:]

    func entry(for url: URL, cacheKey: String) -> DashClipPreviewCacheEntry? {
        guard let entry = entries[url.path], entry.cacheKey == cacheKey else { return nil }
        return entry
    }

    func store(_ entry: DashClipPreviewCacheEntry, for url: URL) {
        entries[url.path] = entry
    }
}

final class DashClipLibrary: ObservableObject {
    
    // clips
    
    // the current clip list shown in the ui
    
    @Published var clips: [DashClipFile] = []
    private let previewCache = DashClipPreviewCache.shared
    private var reloadTask: Task<Void, Never>?

    deinit {
        reloadTask?.cancel()
    }
    
    func reload() {
        reloadTask?.cancel()
        reloadTask = Task(priority: .userInitiated) {
            do {
                let clipFiles = try await loadClipIndex()
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.clips = clipFiles
                }

                await loadPreviews(for: clipFiles)
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.clips = []
                }
            }
        }
    }
    
    func delete(in section: DashClipDaySection, at offsets: IndexSet) {
        let targets = offsets.map { section.clips[$0] }
        
        for clip in targets {
            try? FileManager.default.removeItem(at: clip.url)
            DashClipMetadataStore.remove(for: clip.url)
        }
        
        reload()
    }

    private func loadClipIndex() async throws -> [DashClipFile] {
        let folderURL = try DashCamController.clipsFolderURL()
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        let urls = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )?.compactMap { $0 as? URL } ?? []

        var clipFiles = [DashClipFile]()
        clipFiles.reserveCapacity(urls.count)

        for url in urls {
            guard !Task.isCancelled else { break }
            guard let clip = await indexedClipFile(at: url, resourceKeys: resourceKeys) else { continue }
            clipFiles.append(clip)
        }

        return clipFiles.sorted { $0.date > $1.date }
    }

    private func indexedClipFile(at url: URL, resourceKeys: Set<URLResourceKey>) async -> DashClipFile? {
        guard !url.pathComponents.contains(DashCamController.retroBufferFolderName) else { return nil }

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
        let metadata = DashClipMetadataStore.load(for: url)
        let cacheKey = previewCacheKey(for: url, date: date, size: size)
        let cachedPreview = await previewCache.entry(for: url, cacheKey: cacheKey)

        return DashClipFile(
            url: url,
            date: date,
            size: size,
            kind: kind,
            metadata: metadata,
            durationSeconds: cachedPreview?.durationSeconds,
            thumbnailData: cachedPreview?.thumbnailData
        )
    }

    private func loadPreviews(for clips: [DashClipFile]) async {
        for clip in clips {
            guard !Task.isCancelled else { return }
            guard clip.thumbnailData == nil || (clip.kind.isMovie && clip.durationSeconds == nil) else { continue }

            let cacheKey = previewCacheKey(for: clip.url, date: clip.date, size: clip.size)
            let durationSeconds: Double?
            if let cachedDuration = clip.durationSeconds {
                durationSeconds = cachedDuration
            } else {
                durationSeconds = await mediaDuration(for: clip.url, kind: clip.kind)
            }

            let resolvedThumbnailData: Data?
            if let cachedThumbnail = clip.thumbnailData {
                resolvedThumbnailData = cachedThumbnail
            } else {
                resolvedThumbnailData = await thumbnailData(for: clip.url, kind: clip.kind)
            }
            guard !Task.isCancelled else { return }

            await previewCache.store(
                DashClipPreviewCacheEntry(
                    cacheKey: cacheKey,
                    durationSeconds: durationSeconds,
                    thumbnailData: resolvedThumbnailData
                ),
                for: clip.url
            )

            await MainActor.run {
                guard let index = self.clips.firstIndex(where: { $0.id == clip.id }) else { return }
                self.clips[index] = self.clips[index].applyingPreview(
                    durationSeconds: durationSeconds,
                    thumbnailData: resolvedThumbnailData
                )
            }
        }
    }

    private func previewCacheKey(for url: URL, date: Date, size: Int64) -> String {
        "\(url.path)|\(date.timeIntervalSinceReferenceDate)|\(size)"
    }

    private func mediaDuration(for url: URL, kind: DashClipKind) async -> Double? {
        guard kind.isMovie else { return nil }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    private func previewTime(for asset: AVURLAsset) async -> CMTime {
        guard let duration = try? await asset.load(.duration) else {
            return .zero
        }

        let seconds = CMTimeGetSeconds(duration)
        let previewSecond = seconds.isFinite ? min(0.6, max(seconds * 0.2, 0)) : 0
        return CMTime(seconds: previewSecond, preferredTimescale: 600)
    }

    private func generateImage(for generator: AVAssetImageGenerator, at time: CMTime) async -> CGImage? {
        do {
            let result = try await generator.image(at: time)
            return result.image
        } catch {
            return nil
        }
    }

    private func thumbnailData(for url: URL, kind: DashClipKind) async -> Data? {
        switch kind {
        case .photo:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 184
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.78)
        case .movie:
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 184, height: 112)
            let time = await previewTime(for: asset)
            guard let cgImage = await generateImage(for: generator, at: time) else { return nil }
            return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.78)
        }
    }
}
