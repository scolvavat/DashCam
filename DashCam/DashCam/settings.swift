//
//  settings.swift
//  DashCam
//
//  Created by Muhanned Alkhafaji on 3/1/26.
//

import SwiftUI

// settings screen

// move the controls out of the main camera screen so the preview stays clean

// this file only depends on DashCamController and the enums already living in your main dashcam file

struct DashCamSettingsView: View {
    
    private enum SettingsPicker: String, Identifiable {
        case recordingMode
        case quality
        case frameRate
        case clipLength
        case storageCap
        case autoStartThreshold
        
        var id: String { rawValue }
    }
    
    @ObservedObject var camera: DashCamController
    @Environment(\.dismiss) private var dismiss

    // local draft values

    // keep picker and toggle interaction local to this screen so live camera
    // status updates do not fight with the controls while the user is tapping.

    @State private var draftRecordingMode: RecordingMode = .pipSingleFile
    @State private var draftQuality: DashVideoQuality = .p720
    @State private var draftClipLength: DashClipLength = .s30
    @State private var draftStorageCap: DashStorageCap = .gb5
    @State private var draftFrameRate: DashFrameRate = .fps24
    @State private var draftAutoStartBySpeed: Bool = false
    @State private var draftAutoStartThresholdMPH: Double = 5
    @State private var draftBurnStamp: Bool = true
    @State private var draftShowFrontPreview: Bool = true
    @State private var draftShowCompass: Bool = false
    @State private var draftShowMainStatusBadges: Bool = false
    @State private var draftShowMainExtraInfo: Bool = false
    @State private var activePicker: SettingsPicker?
    
    var body: some View {
        NavigationStack {
            Form {
                recordingSection
                loopSection
                autoStartSection
                overlaySection
                statusSection
                actionsSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                }
            }
        }
        .onAppear {
            syncDraftsFromCamera()
        }
        .sheet(item: $activePicker) { picker in
            pickerSheet(for: picker)
        }
    }
    
    private var recordingSection: some View {
        Section {
            settingsSelectionRow(title: "Recording mode", value: draftRecordingMode.label) {
                activePicker = .recordingMode
            }
            
            settingsSelectionRow(title: "Quality", value: draftQuality.label) {
                activePicker = .quality
            }

            settingsSelectionRow(title: "Frame rate", value: draftFrameRate.label) {
                activePicker = .frameRate
            }
            
            settingsNote("Quality and mode changes apply to the next new segment or the next recording start.")
        } header: {
            Text("Recording")
        }
    }
    
    private var loopSection: some View {
        Section {
            settingsSelectionRow(title: "Clip length", value: draftClipLength.label) {
                activePicker = .clipLength
            }
            
            settingsSelectionRow(title: "Storage cap", value: draftStorageCap.label) {
                activePicker = .storageCap
            }
            
            settingsValueRow(title: "Current loop status", value: camera.loopStatusText)
        } header: {
            Text("Loop storage")
        }
    }
    
    private var autoStartSection: some View {
        Section {
            Toggle("Auto start by speed", isOn: $draftAutoStartBySpeed)
                .onChange(of: draftAutoStartBySpeed) { _, newValue in
                    camera.autoStartBySpeed = newValue
                }

            settingsSelectionRow(title: "Start threshold", value: "\(Int(draftAutoStartThresholdMPH)) mph") {
                activePicker = .autoStartThreshold
            }
            .disabled(!draftAutoStartBySpeed)

            settingsValueRow(title: "Live speed", value: camera.speedStatusText)
            settingsNote("Foreground only. If the app is backgrounded or closed, it stops recording and ignores speed updates.")
        } header: {
            Text("Auto start")
        }
    }

    private var overlaySection: some View {
        Section {
            Toggle("Burn date, time, and GPS on video", isOn: $draftBurnStamp)
                .onChange(of: draftBurnStamp) { _, newValue in
                    camera.burnStamp = newValue
                }

            Toggle("Show front PiP preview", isOn: $draftShowFrontPreview)
                .onChange(of: draftShowFrontPreview) { _, newValue in
                    camera.showFrontPreview = newValue
                }

            Toggle("Show compass", isOn: $draftShowCompass)
                .onChange(of: draftShowCompass) { _, newValue in
                    camera.showCompass = newValue
                }

            Toggle("Show main screen status badges", isOn: $draftShowMainStatusBadges)
                .onChange(of: draftShowMainStatusBadges) { _, newValue in
                    camera.showMainStatusBadges = newValue
                }

            Toggle("Show extra main screen info", isOn: $draftShowMainExtraInfo)
                .onChange(of: draftShowMainExtraInfo) { _, newValue in
                    camera.showMainExtraInfo = newValue
                }
            
            settingsNote("PiP preview only changes the small on-screen front camera box. Recording mode still controls whether the app saves one PiP file or two separate files.")
        } header: {
            Text("Overlay and preview")
        }
    }
    
    private var statusSection: some View {
        Section {
            settingsValueRow(title: "Camera", value: camera.statusText)
            settingsValueRow(title: "Detail", value: camera.detailText)
            settingsValueRow(title: "Last saved", value: camera.savedClipText)
            settingsValueRow(title: "Live stamp", value: camera.liveStampText)
            settingsValueRow(title: "Speed", value: camera.speedStatusText)
        } header: {
            Text("Status")
        }
    }
    
    private var actionsSection: some View {
        Section {
            Button {
                camera.restart()
            } label: {
                Label("Restart camera", systemImage: "arrow.clockwise")
            }
            .disabled(camera.isRecording)
            
            Button {
                camera.clearSavedClipText()
            } label: {
                Label("Clear saved status", systemImage: "trash")
            }
            
            if camera.isRecording {
                settingsNote("Stop recording before restarting the camera.")
            }
        } header: {
            Text("Actions")
        }
    }
    
    private func settingsValueRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
    
    private func settingsNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func settingsSelectionRow(title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func pickerSheet(for picker: SettingsPicker) -> some View {
        switch picker {
        case .recordingMode:
            selectionSheet(
                title: "Recording mode",
                rows: RecordingMode.allCases.map { SelectionRow(id: $0.id, title: $0.label, isSelected: draftRecordingMode == $0) },
                onSelect: { id in
                    guard let mode = RecordingMode.allCases.first(where: { $0.id == id }) else { return }
                    draftRecordingMode = mode
                    camera.recordingMode = mode
                }
            )
        case .quality:
            selectionSheet(
                title: "Quality",
                rows: DashVideoQuality.allCases.map { SelectionRow(id: $0.id, title: $0.label, isSelected: draftQuality == $0) },
                onSelect: { id in
                    guard let quality = DashVideoQuality.allCases.first(where: { $0.id == id }) else { return }
                    draftQuality = quality
                    camera.quality = quality
                }
            )
        case .frameRate:
            selectionSheet(
                title: "Frame rate",
                rows: DashFrameRate.allCases.map { SelectionRow(id: String($0.id), title: $0.label, isSelected: draftFrameRate == $0) },
                onSelect: { id in
                    guard let rawValue = Int(id), let frameRate = DashFrameRate(rawValue: rawValue) else { return }
                    draftFrameRate = frameRate
                    camera.frameRate = frameRate
                }
            )
        case .clipLength:
            selectionSheet(
                title: "Clip length",
                rows: DashClipLength.allCases.map { SelectionRow(id: String($0.id), title: $0.label, isSelected: draftClipLength == $0) },
                onSelect: { id in
                    guard let rawValue = Int(id), let clipLength = DashClipLength(rawValue: rawValue) else { return }
                    draftClipLength = clipLength
                    camera.clipLength = clipLength
                }
            )
        case .storageCap:
            selectionSheet(
                title: "Storage cap",
                rows: DashStorageCap.allCases.map { SelectionRow(id: String($0.id), title: $0.label, isSelected: draftStorageCap == $0) },
                onSelect: { id in
                    guard let rawValue = Int(id), let storageCap = DashStorageCap(rawValue: rawValue) else { return }
                    draftStorageCap = storageCap
                    camera.storageCap = storageCap
                }
            )
        case .autoStartThreshold:
            let values = [5.0, 10.0, 15.0, 20.0, 25.0]
            selectionSheet(
                title: "Start threshold",
                rows: values.map { SelectionRow(id: String(Int($0)), title: "\(Int($0)) mph", isSelected: draftAutoStartThresholdMPH == $0) },
                onSelect: { id in
                    guard let mph = Double(id) else { return }
                    draftAutoStartThresholdMPH = mph
                    camera.autoStartThresholdMPH = mph
                }
            )
        }
    }

    private func selectionSheet(title: String, rows: [SelectionRow], onSelect: @escaping (String) -> Void) -> some View {
        NavigationStack {
            List(rows) { row in
                Button {
                    onSelect(row.id)
                    activePicker = nil
                } label: {
                    HStack {
                        Text(row.title)
                            .foregroundStyle(.primary)
                        Spacer()
                        if row.isSelected {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        activePicker = nil
                    }
                }
            }
        }
    }

    private struct SelectionRow: Identifiable {
        let id: String
        let title: String
        let isSelected: Bool
    }

    private func syncDraftsFromCamera() {
        draftRecordingMode = camera.recordingMode
        draftQuality = camera.quality
        draftClipLength = camera.clipLength
        draftStorageCap = camera.storageCap
        draftFrameRate = camera.frameRate
        draftAutoStartBySpeed = camera.autoStartBySpeed
        draftAutoStartThresholdMPH = camera.autoStartThresholdMPH
        draftBurnStamp = camera.burnStamp
        draftShowFrontPreview = camera.showFrontPreview
        draftShowCompass = camera.showCompass
        draftShowMainStatusBadges = camera.showMainStatusBadges
        draftShowMainExtraInfo = camera.showMainExtraInfo
    }
}
