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

    @State private var draft = SettingsDraft()
    
    var body: some View {
        NavigationStack {
            Form {
                recordingSection
                loopSection
                autoStartSection
                crashSection
                overlaySection
                convoySection
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
            draftSelectionRow("Recording mode", values: RecordingMode.allCases, draft: \.recordingMode, camera: \.recordingMode) { $0.label }
            draftSelectionRow("Rear lens", values: RearLensOption.allCases, draft: \.rearLens, camera: \.rearLens) { $0.label }
                .disabled(!camera.canSwitchRearLens)
            draftSelectionRow("Quality", values: DashVideoQuality.allCases, draft: \.quality, camera: \.quality) { $0.label }
            draftSelectionRow("Frame rate", values: DashFrameRate.allCases, draft: \.frameRate, camera: \.frameRate) { $0.label }
            draftSelectionRow("Bitrate", values: DashBitrateProfile.allCases, draft: \.bitrateProfile, camera: \.bitrateProfile) { $0.label }
            draftToggle("Enable front camera", draft: \.frontCameraEnabled, camera: \.frontCameraEnabled)
                .disabled(!camera.multiCamSupported || camera.isRecording)
            
            if camera.multiCamSupported {
                settingsNote("Turn the front camera off for rear-only recording and lower CPU load. The live front preview stays hidden either way.")
            } else {
                settingsNote("This device does not support front and rear capture at the same time, so the front camera toggle is unavailable.")
            }

            if camera.isRecording {
                settingsNote("Stop recording before changing the front camera state.")
                settingsNote("Stop recording before switching the rear lens.")
            }

            if !draft.frontCameraEnabled {
                settingsNote("With front camera off, PiP and dual-file modes both record the rear camera only.")
            }

            if !camera.isUltraWideAvailable {
                settingsNote("Ultra-wide is not available on this device, so rear lens stays on 1x.")
            }

            settingsNote("Quality and mode changes apply to the next new segment or the next recording start.")
        } header: {
            Text("Recording")
        }
    }
    
    private var loopSection: some View {
        Section {
            draftSelectionRow("Clip length", values: DashClipLength.allCases, draft: \.clipLength, camera: \.clipLength) { $0.label }
            draftSelectionRow("Retro buffer", values: DashRetroBufferLength.allCases, draft: \.retroBufferLength, camera: \.retroBufferLength) { $0.label }
            draftSelectionRow("Storage cap", values: DashStorageCap.allCases, draft: \.storageCap, camera: \.storageCap) { $0.label }
            
            settingsValueRow(title: "Current loop status", value: camera.loopStatusText)
            settingsNote("Retro buffer controls how far back Record reaches: 30 seconds, 1 minute, or 2 minutes.")
            settingsNote("The rolling buffer stays temporary. Only clips you protect with Record, Save Moment, or crash detection are moved into Clips.")
            settingsNote("When you tap Record, DashCam closes the current buffered segment immediately so the saved clip appears in Clips right away instead of waiting for the next segment rollover.")
        } header: {
            Text("Loop storage")
        }
    }
    
    private var autoStartSection: some View {
        Section {
            let thresholdValues = [5.0, 10.0, 15.0, 20.0, 25.0]

            draftToggle("Auto start by speed", draft: \.autoStartBySpeed, camera: \.autoStartBySpeed)

            draftSelectionRow("Start threshold", values: thresholdValues, draft: \.autoStartThresholdMPH, camera: \.autoStartThresholdMPH) {
                "\(Int($0)) mph"
            }
            .disabled(!draft.autoStartBySpeed)

            settingsValueRow(title: "Live speed", value: camera.speedStatusText)
            settingsNote("Foreground only. If the speed threshold is reached, the app now protects the buffered minute first, then keeps saving new segments until speed drops back below the stop threshold.")
        } header: {
            Text("Auto start")
        }
    }

    private var overlaySection: some View {
        Section {
            draftToggle("Burn date, time, and GPS on video", draft: \.burnStamp, camera: \.burnStamp)
            draftToggle("Use map as main background", draft: \.showMapBackground, camera: \.showMapBackground)
            draftToggle("Show compass", draft: \.showCompass, camera: \.showCompass)
            draftToggle("Show extra main screen info", draft: \.showMainExtraInfo, camera: \.showMainExtraInfo)
            
            settingsNote("The live front preview is hidden to keep recording smoother. Recording mode still controls whether the app saves one PiP file or two separate files.")
        } header: {
            Text("Overlay and preview")
        }
    }
    
    private var statusSection: some View {
        Section {
            ForEach(statusRows, id: \.title) { row in
                settingsValueRow(title: row.title, value: row.value)
            }
        } header: {
            Text("Status")
        }
    }

    private var crashSection: some View {
        Section {
            draftToggle("Enable crash detection", draft: \.crashDetectionEnabled, camera: \.crashDetectionEnabled)

            draftSelectionRow("Sensitivity", values: DashCrashSensitivity.allCases, draft: \.crashSensitivity, camera: \.crashSensitivity) {
                $0.label
            }
            .disabled(!draft.crashDetectionEnabled)

            settingsValueRow(title: "Live status", value: camera.crashStatusText)
            settingsNote("Foreground only. This is a motion-spike detector and can trigger on potholes or harsh bumps.")
        } header: {
            Text("Crash detection")
        }
    }

    private var convoySection: some View {
        Section {
            draftToggle("Enable convoy live map", draft: \.convoyEnabled, camera: \.convoyEnabled)

            TextField("Server URL", text: draftBinding(\.convoyServerURL))
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .keyboardType(.URL)
                .onChange(of: draft.convoyServerURL) { _, newValue in
                    camera.convoyServerURL = newValue
                }

            TextField("Session code", text: draftBinding(\.convoySessionCode))
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .onChange(of: draft.convoySessionCode) { _, newValue in
                    camera.convoySessionCode = newValue
                }

            TextField("Display name", text: draftBinding(\.convoyDisplayName))
                .disableAutocorrection(true)
                .onChange(of: draft.convoyDisplayName) { _, newValue in
                    camera.convoyDisplayName = newValue
                }

            settingsValueRow(title: "Live status", value: camera.convoyStatusText)
            settingsNote("Use ws://127.0.0.1:8787 for simulator on your Mac. Use a tunnel URL (wss://...) for physical phones.")
        } header: {
            Text("Convoy")
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

    private var statusRows: [(title: String, value: String)] {
        [
            ("Camera", camera.statusText),
            ("Detail", camera.detailText),
            ("Last saved", camera.savedClipText),
            ("Live stamp", camera.liveStampText),
            ("Speed", camera.speedStatusText),
            ("Crash detection", camera.crashStatusText),
            ("Convoy", camera.convoyStatusText)
        ]
    }

    private func draftBinding<Value>(_ keyPath: WritableKeyPath<SettingsDraft, Value>) -> Binding<Value> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { draft[keyPath: keyPath] = $0 }
        )
    }

    private func draftToggle(
        _ title: String,
        draft draftKeyPath: WritableKeyPath<SettingsDraft, Bool>,
        camera cameraKeyPath: ReferenceWritableKeyPath<DashCamController, Bool>
    ) -> some View {
        Toggle(title, isOn: draftBinding(draftKeyPath))
            .onChange(of: draft[keyPath: draftKeyPath]) { _, newValue in
                camera[keyPath: cameraKeyPath] = newValue
            }
    }

    private func draftSelectionRow<Value: Hashable>(
        _ title: String,
        values: [Value],
        draft draftKeyPath: WritableKeyPath<SettingsDraft, Value>,
        camera cameraKeyPath: ReferenceWritableKeyPath<DashCamController, Value>,
        label: @escaping (Value) -> String
    ) -> some View {
        NavigationLink {
            SettingsSelectionList(
                title: title,
                values: values,
                selection: Binding(
                    get: { draft[keyPath: draftKeyPath] },
                    set: { newValue in
                        draft[keyPath: draftKeyPath] = newValue
                        camera[keyPath: cameraKeyPath] = newValue
                    }
                ),
                label: label
            )
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text(label(draft[keyPath: draftKeyPath]))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func syncDraftsFromCamera() {
        draft = SettingsDraft(camera: camera)
    }

    private struct SettingsDraft {
        var recordingMode: RecordingMode = .pipSingleFile
        var frontCameraEnabled: Bool = true
        var rearLens: RearLensOption = .wide
        var quality: DashVideoQuality = .p720
        var bitrateProfile: DashBitrateProfile = .balanced
        var clipLength: DashClipLength = .s30
        var retroBufferLength: DashRetroBufferLength = .s60
        var storageCap: DashStorageCap = .gb5
        var frameRate: DashFrameRate = .fps24
        var autoStartBySpeed: Bool = false
        var autoStartThresholdMPH: Double = 5
        var burnStamp: Bool = true
        var showCompass: Bool = false
        var showMainExtraInfo: Bool = false
        var showMapBackground: Bool = true
        var convoyEnabled: Bool = false
        var convoyServerURL: String = "ws://127.0.0.1:8787"
        var convoySessionCode: String = "test-drive"
        var convoyDisplayName: String = ""
        var crashDetectionEnabled: Bool = false
        var crashSensitivity: DashCrashSensitivity = .balanced

        init() {}

        init(camera: DashCamController) {
            recordingMode = camera.recordingMode
            frontCameraEnabled = camera.frontCameraEnabled
            rearLens = camera.rearLens
            quality = camera.quality
            bitrateProfile = camera.bitrateProfile
            clipLength = camera.clipLength
            retroBufferLength = camera.retroBufferLength
            storageCap = camera.storageCap
            frameRate = camera.frameRate
            autoStartBySpeed = camera.autoStartBySpeed
            autoStartThresholdMPH = camera.autoStartThresholdMPH
            burnStamp = camera.burnStamp
            showCompass = camera.showCompass
            showMainExtraInfo = camera.showMainExtraInfo
            showMapBackground = camera.showMapBackground
            convoyEnabled = camera.convoyEnabled
            convoyServerURL = camera.convoyServerURL
            convoySessionCode = camera.convoySessionCode
            convoyDisplayName = camera.convoyDisplayName
            crashDetectionEnabled = camera.crashDetectionEnabled
            crashSensitivity = camera.crashSensitivity
        }
    }
}

private struct SettingsSelectionList<Value: Hashable>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let values: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    var body: some View {
        List(values, id: \.self) { value in
            Button {
                selection = value
                dismiss()
            } label: {
                HStack {
                    Text(label(value))
                    Spacer()
                    if value == selection {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.blue)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
