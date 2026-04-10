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

    @ObservedObject var camera: DashCamController
    @Environment(\.dismiss) private var dismiss

    // local draft values

    // keep picker and toggle interaction local to this screen so live camera
    // status updates do not fight with the controls while the user is tapping.

    @State private var draftRecordingMode: RecordingMode = .pipSingleFile
    @State private var draftQuality: DashVideoQuality = .p720
    @State private var draftBitrateProfile: DashBitrateProfile = .balanced
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
    @State private var draftShowMapBackground: Bool = true
    
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
    }
    
    private var recordingSection: some View {
        Section {
            Picker("Recording mode", selection: $draftRecordingMode) {
                ForEach(RecordingMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: draftRecordingMode) { _, newValue in
                camera.recordingMode = newValue
            }
            
            Picker("Quality", selection: $draftQuality) {
                ForEach(DashVideoQuality.allCases) { quality in
                    Text(quality.label).tag(quality)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: draftQuality) { _, newValue in
                camera.quality = newValue
            }

            Picker("Frame rate", selection: $draftFrameRate) {
                ForEach(DashFrameRate.allCases) { frameRate in
                    Text(frameRate.label).tag(frameRate)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: draftFrameRate) { _, newValue in
                camera.frameRate = newValue
            }

            Picker("Bitrate", selection: $draftBitrateProfile) {
                ForEach(DashBitrateProfile.allCases) { profile in
                    Text(profile.label).tag(profile)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: draftBitrateProfile) { _, newValue in
                camera.bitrateProfile = newValue
            }
            
            settingsNote("Quality and mode changes apply to the next new segment or the next recording start.")
        } header: {
            Text("Recording")
        }
    }
    
    private var loopSection: some View {
        Section {
            Picker("Clip length", selection: $draftClipLength) {
                ForEach(DashClipLength.allCases) { clipLength in
                    Text(clipLength.label).tag(clipLength)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: draftClipLength) { _, newValue in
                camera.clipLength = newValue
            }
            
            Picker("Storage cap", selection: $draftStorageCap) {
                ForEach(DashStorageCap.allCases) { storageCap in
                    Text(storageCap.label).tag(storageCap)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: draftStorageCap) { _, newValue in
                camera.storageCap = newValue
            }
            
            settingsValueRow(title: "Current loop status", value: camera.loopStatusText)
        } header: {
            Text("Loop storage")
        }
    }
    
    private var autoStartSection: some View {
        Section {
            let thresholdValues = [5.0, 10.0, 15.0, 20.0, 25.0]

            Toggle("Auto start by speed", isOn: $draftAutoStartBySpeed)
                .onChange(of: draftAutoStartBySpeed) { _, newValue in
                    camera.autoStartBySpeed = newValue
                }

            Picker("Start threshold", selection: $draftAutoStartThresholdMPH) {
                ForEach(thresholdValues, id: \.self) { mph in
                    Text("\(Int(mph)) mph").tag(mph)
                }
            }
            .pickerStyle(.menu)
            .disabled(!draftAutoStartBySpeed)
            .onChange(of: draftAutoStartThresholdMPH) { _, newValue in
                camera.autoStartThresholdMPH = newValue
            }

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

            Toggle("Use map as main background", isOn: $draftShowMapBackground)
                .onChange(of: draftShowMapBackground) { _, newValue in
                    camera.showMapBackground = newValue
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

    private func syncDraftsFromCamera() {
        draftRecordingMode = camera.recordingMode
        draftQuality = camera.quality
        draftBitrateProfile = camera.bitrateProfile
        draftClipLength = camera.clipLength
        draftStorageCap = camera.storageCap
        draftFrameRate = camera.frameRate
        draftAutoStartBySpeed = camera.autoStartBySpeed
        draftAutoStartThresholdMPH = camera.autoStartThresholdMPH
        draftBurnStamp = camera.burnStamp
        draftShowFrontPreview = camera.showFrontPreview
        draftShowMapBackground = camera.showMapBackground
        draftShowCompass = camera.showCompass
        draftShowMainStatusBadges = camera.showMainStatusBadges
        draftShowMainExtraInfo = camera.showMainExtraInfo
    }
}
