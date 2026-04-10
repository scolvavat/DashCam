//
//  DashCamController.swift
//  DashCam
//
//  Created by Muhanned Alkhafaji on 3/1/26.
//

import SwiftUI
import AVFoundation
import Combine
import UIKit
import CoreLocation
import CoreImage
import CoreText

final class DashCamController: NSObject, ObservableObject {

    // saved settings keys

    // keep the user facing app choices across launches so the app comes back
    // in the same recording configuration the user last picked.

    private enum SavedSettingKey {
        static let recordingMode = "dashcam.recordingMode"
        static let rearLens = "dashcam.rearLens"
        static let quality = "dashcam.quality"
        static let bitrateProfile = "dashcam.bitrateProfile"
        static let clipLength = "dashcam.clipLength"
        static let storageCap = "dashcam.storageCap"
        static let frameRate = "dashcam.frameRate"
        static let burnStamp = "dashcam.burnStamp"
        static let showFrontPreview = "dashcam.showFrontPreview"
        static let showCompass = "dashcam.showCompass"
        static let showMainStatusBadges = "dashcam.showMainStatusBadges"
        static let showMainExtraInfo = "dashcam.showMainExtraInfo"
        static let showMapBackground = "dashcam.showMapBackground"
        static let autoStartBySpeed = "dashcam.autoStartBySpeed"
        static let autoStartThresholdMPH = "dashcam.autoStartThresholdMPH"
    }

    private static func savedRecordingMode() -> RecordingMode {
        let defaults = UserDefaults.standard
        guard let rawValue = defaults.string(forKey: SavedSettingKey.recordingMode),
              let value = RecordingMode(rawValue: rawValue) else {
            return .pipSingleFile
        }
        return value
    }

    private static func savedQuality() -> DashVideoQuality {
        let defaults = UserDefaults.standard
        guard let rawValue = defaults.string(forKey: SavedSettingKey.quality),
              let value = DashVideoQuality(rawValue: rawValue) else {
            return .p720
        }
        return value
    }

    private static func savedBitrateProfile() -> DashBitrateProfile {
        let defaults = UserDefaults.standard
        guard let rawValue = defaults.string(forKey: SavedSettingKey.bitrateProfile),
              let value = DashBitrateProfile(rawValue: rawValue) else {
            return .balanced
        }
        return value
    }

    private static func savedRearLens() -> RearLensOption {
        let defaults = UserDefaults.standard
        guard let rawValue = defaults.string(forKey: SavedSettingKey.rearLens),
              let value = RearLensOption(rawValue: rawValue) else {
            return .wide
        }
        return value
    }

    private static func savedClipLength() -> DashClipLength {
        let defaults = UserDefaults.standard
        guard let value = DashClipLength(rawValue: defaults.integer(forKey: SavedSettingKey.clipLength)) else {
            return .s30
        }
        return value
    }

    private static func savedStorageCap() -> DashStorageCap {
        let defaults = UserDefaults.standard
        guard let value = DashStorageCap(rawValue: defaults.integer(forKey: SavedSettingKey.storageCap)) else {
            return .gb5
        }
        return value
    }

    private static func savedFrameRate() -> DashFrameRate {
        let defaults = UserDefaults.standard
        guard let value = DashFrameRate(rawValue: defaults.integer(forKey: SavedSettingKey.frameRate)) else {
            return .fps24
        }
        return value
    }

    private static func savedBool(forKey key: String, default defaultValue: Bool) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    private static func savedAutoStartThresholdMPH() -> Double {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: SavedSettingKey.autoStartThresholdMPH) != nil else {
            return 5
        }
        return defaults.double(forKey: SavedSettingKey.autoStartThresholdMPH)
    }

    @Published var showAlert: Bool = false
    @Published var alertMessage: String = ""
    @Published var isRunning: Bool = false
    @Published var isCaptureReady: Bool = false
    @Published var isAudioReady: Bool = false
    @Published var isRecording: Bool = false
    @Published var detailText: String = "Waiting for camera permission..."
    @Published var savedClipText: String = "No clips saved yet."
    @Published var loopStatusText: String = "Loop 30s • cap 5 GB • local use unknown"
    @Published var recordingMode: RecordingMode = DashCamController.savedRecordingMode() {
        didSet {
            guard recordingMode != oldValue else { return }
            saveSettings()
        }
    }
    @Published var rearLens: RearLensOption = DashCamController.savedRearLens() {
        didSet {
            guard rearLens != oldValue else { return }
            saveSettings()
            applyRearLensChangeIfNeeded()
        }
    }
    @Published var quality: DashVideoQuality = DashCamController.savedQuality() {
        didSet {
            guard quality != oldValue else { return }
            saveSettings()
            refreshLoopStatusText()
            applyCurrentCaptureFormatsIfPossible()
        }
    }
    @Published var bitrateProfile: DashBitrateProfile = DashCamController.savedBitrateProfile() {
        didSet {
            guard bitrateProfile != oldValue else { return }
            saveSettings()
        }
    }
    @Published var clipLength: DashClipLength = DashCamController.savedClipLength() {
        didSet {
            guard clipLength != oldValue else { return }
            saveSettings()
            refreshLoopStatusText()
            restartLoopTimerIfNeeded()
        }
    }
    @Published var storageCap: DashStorageCap = DashCamController.savedStorageCap() {
        didSet {
            guard storageCap != oldValue else { return }
            saveSettings()
            refreshLoopStatusText()
            captureQueue.async {
                self.trimStorageIfNeeded(protecting: self.currentSegmentProtectedURLs())
            }
        }
    }
    @Published var frameRate: DashFrameRate = DashCamController.savedFrameRate() {
        didSet {
            guard frameRate != oldValue else { return }
            saveSettings()
            applyCurrentCaptureFormatsIfPossible()
        }
    }
    @Published var burnStamp: Bool = DashCamController.savedBool(forKey: SavedSettingKey.burnStamp, default: true) {
        didSet {
            guard burnStamp != oldValue else { return }
            saveSettings()
        }
    }
    @Published var showFrontPreview: Bool = DashCamController.savedBool(forKey: SavedSettingKey.showFrontPreview, default: true) {
        didSet {
            guard showFrontPreview != oldValue else { return }
            saveSettings()
        }
    }
    @Published var showCompass: Bool = DashCamController.savedBool(forKey: SavedSettingKey.showCompass, default: false) {
        didSet {
            guard showCompass != oldValue else { return }
            saveSettings()
        }
    }
    @Published var showMainStatusBadges: Bool = DashCamController.savedBool(forKey: SavedSettingKey.showMainStatusBadges, default: false) {
        didSet {
            guard showMainStatusBadges != oldValue else { return }
            saveSettings()
        }
    }
    @Published var showMainExtraInfo: Bool = DashCamController.savedBool(forKey: SavedSettingKey.showMainExtraInfo, default: false) {
        didSet {
            guard showMainExtraInfo != oldValue else { return }
            saveSettings()
        }
    }
    @Published var showMapBackground: Bool = DashCamController.savedBool(forKey: SavedSettingKey.showMapBackground, default: true) {
        didSet {
            guard showMapBackground != oldValue else { return }
            saveSettings()
        }
    }
    @Published var frontPreviewImage: UIImage?
    @Published var liveStampText: String = "GPS waiting..."
    @Published var autoStartBySpeed: Bool = DashCamController.savedBool(forKey: SavedSettingKey.autoStartBySpeed, default: false) {
        didSet {
            guard autoStartBySpeed != oldValue else { return }
            saveSettings()
            handleAutoStartToggleChange()
        }
    }
    @Published var autoStartThresholdMPH: Double = DashCamController.savedAutoStartThresholdMPH() {
        didSet {
            guard autoStartThresholdMPH != oldValue else { return }
            saveSettings()
            resetAutoSpeedCounters()
            updateSpeedStatusText(with: locationManager.speedMetersPerSecond)
        }
    }
    @Published var speedStatusText: String = "Speed 0.0 mph • auto start off"

    let session: AVCaptureSession
    let locationManager = DashLocationManager()

    let sessionQueue = DispatchQueue(label: "dashcam.session.queue")
    let captureQueue = DispatchQueue(label: "dashcam.capture.queue")
    let frontPreviewQueue = DispatchQueue(label: "dashcam.front.preview.queue")
    let ciContext = CIContext(options: nil)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let multiSessionSupported: Bool = AVCaptureMultiCamSession.isMultiCamSupported
    var didConfigureSession: Bool = false
    var isStartingSession: Bool = false
    weak var previewLayer: AVCaptureVideoPreviewLayer?
    var hasAttachedPreviewConnection: Bool = false
    var liveClockTimer: Timer?
    var currentClockText: String = ""
    var cancellables = Set<AnyCancellable>()
    var orientationObserver: NSObjectProtocol?

    var rearVideoInput: AVCaptureDeviceInput?
    var frontVideoInput: AVCaptureDeviceInput?
    var audioInput: AVCaptureDeviceInput?

    let rearVideoOutput = AVCaptureVideoDataOutput()
    let frontVideoOutput = AVCaptureVideoDataOutput()
    let audioOutput = AVCaptureAudioDataOutput()

    var latestFrontPixelBuffer: CVPixelBuffer?
    var lastFrontPreviewPush: CFTimeInterval = 0
    var lastFrontPiPBufferPush: CFTimeInterval = 0
    var isFrontPreviewRenderInFlight: Bool = false
    var activeLoopRecording: ActiveLoopRecording?
    var isSceneActive: Bool = true
    var pendingManualRecordingRequest: Bool = false
    var hasPreparedAudioSession: Bool = false
    var consecutiveAboveThresholdCount: Int = 0
    var consecutiveBelowThresholdCount: Int = 0
    var isAutoSpeedRecording: Bool = false
    var pendingRearPhotoCaptureCount: Int = 0
    var rearWarmupFrameCount: Int = 0
    var audioWarmupSampleCount: Int = 0
    let rearWarmupFramesRequired: Int = 6
    let audioWarmupSamplesRequired: Int = 3
    let frontPreviewTargetSize = CGSize(width: 320, height: 420)
    let frontPreviewTargetSizeAt60FPS = CGSize(width: 220, height: 300)

    // cached stamp overlay

    // text only changes once a second so build the overlay once and reuse it instead of redrawing it every frame

    var cachedStampKey: String = ""
    var cachedStampOverlay: CIImage?
    var cachedPiPBorderKey: String = ""
    var cachedPiPBorderOverlay: CIImage?

    // rotation state

    // preview updates live

    // each active clip freezes the current angles at the moment recording starts

    var rearPreviewAngle: CGFloat = 0
    var rearCaptureAngle: CGFloat = 0
    var frontCaptureAngle: CGFloat = 0

    override init() {
        if AVCaptureMultiCamSession.isMultiCamSupported {
            session = AVCaptureMultiCamSession()
        } else {
            session = AVCaptureSession()
        }

        super.init()

        locationManager.$coordinateText
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateLiveStampText()
            }
            .store(in: &cancellables)

        locationManager.$speedMetersPerSecond
            .receive(on: RunLoop.main)
            .sink { [weak self] speed in
                self?.handleSpeedUpdate(speed)
            }
            .store(in: &cancellables)

        refreshLoopStatusText()
        updateSpeedStatusText(with: nil)
    }

    deinit {
        liveClockTimer?.invalidate()
        if let orientationObserver {
            NotificationCenter.default.removeObserver(orientationObserver)
        }
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    static func clipsFolderURL() throws -> URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let folderURL = documentsURL.appendingPathComponent("DashCamClips", isDirectory: true)

        if !FileManager.default.fileExists(atPath: folderURL.path) {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        }

        return folderURL
    }

    func recordingTimestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }

    func photoTimestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss_SSS"
        return formatter.string(from: Date())
    }

    func photosFolderURL() throws -> URL {
        let folderURL = try Self.clipsFolderURL().appendingPathComponent("Snapshots", isDirectory: true)

        if !FileManager.default.fileExists(atPath: folderURL.path) {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        }

        return folderURL
    }

    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(recordingMode.rawValue, forKey: SavedSettingKey.recordingMode)
        defaults.set(rearLens.rawValue, forKey: SavedSettingKey.rearLens)
        defaults.set(quality.rawValue, forKey: SavedSettingKey.quality)
        defaults.set(bitrateProfile.rawValue, forKey: SavedSettingKey.bitrateProfile)
        defaults.set(clipLength.rawValue, forKey: SavedSettingKey.clipLength)
        defaults.set(storageCap.rawValue, forKey: SavedSettingKey.storageCap)
        defaults.set(frameRate.rawValue, forKey: SavedSettingKey.frameRate)
        defaults.set(burnStamp, forKey: SavedSettingKey.burnStamp)
        defaults.set(showFrontPreview, forKey: SavedSettingKey.showFrontPreview)
        defaults.set(showCompass, forKey: SavedSettingKey.showCompass)
        defaults.set(showMainStatusBadges, forKey: SavedSettingKey.showMainStatusBadges)
        defaults.set(showMainExtraInfo, forKey: SavedSettingKey.showMainExtraInfo)
        defaults.set(showMapBackground, forKey: SavedSettingKey.showMapBackground)
        defaults.set(autoStartBySpeed, forKey: SavedSettingKey.autoStartBySpeed)
        defaults.set(autoStartThresholdMPH, forKey: SavedSettingKey.autoStartThresholdMPH)
        defaults.synchronize()
    }

    var multiCamSupported: Bool {
        multiSessionSupported
    }

    var rearTargetFrameRate: Double {
        frameRate.framesPerSecond
    }

    var frontTargetFrameRate: Double {
        24
    }

    var frontTargetQuality: DashVideoQuality {
        .p720
    }

    func adjustedBitrate(for quality: DashVideoQuality) -> Int {
        let adjusted = Int(Double(quality.bitRate) * bitrateProfile.multiplier)
        return max(1_000_000, adjusted)
    }

    var isUltraWideAvailable: Bool {
        AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil
    }

    var canSwitchRearLens: Bool {
        isUltraWideAvailable && !isRecording
    }

    var rearLensButtonLabel: String {
        rearLens.shortLabel
    }

    var compassText: String? {
        guard let heading = locationManager.headingDegrees else { return nil }
        let normalized = Int(round(heading)).quotientAndRemainder(dividingBy: 360).remainder
        let positive = normalized >= 0 ? normalized : normalized + 360
        return "\(headingDirection(for: positive)) \(positive)°"
    }

    func headingDirection(for heading: Int) -> String {
        switch heading {
        case 23..<68:
            return "NE"
        case 68..<113:
            return "E"
        case 113..<158:
            return "SE"
        case 158..<203:
            return "S"
        case 203..<248:
            return "SW"
        case 248..<293:
            return "W"
        case 293..<338:
            return "NW"
        default:
            return "N"
        }
    }

    var statusText: String {
        if isRecording {
            return "RECORDING"
        } else if isRunning {
            return "CAMERA READY"
        } else {
            return "CAMERA OFF"
        }
    }

    var statusColor: Color {
        if isRecording {
            return Color.red.opacity(0.95)
        } else if isRunning {
            return Color.green.opacity(0.9)
        } else {
            return Color.orange.opacity(0.9)
        }
    }

    var canRecord: Bool {
        isCaptureReady && isAudioReady
    }

    func start() {
        if rearLens == .ultraWide && !isUltraWideAvailable {
            rearLens = .wide
        }

        isSceneActive = true
        startLiveClock()
        startOrientationTracking()
        locationManager.start()
        requestPermissionsThenStart()
    }

    func stop() {
        isSceneActive = false
        locationManager.stop()
        stopRecordingIfNeeded(reason: "Stopping camera...")
        pendingManualRecordingRequest = false
        resetCaptureReadiness(includeAudio: audioInput != nil)

        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }

            DispatchQueue.main.async {
                self.isRunning = false
                if !self.isRecording {
                    self.detailText = "Camera stopped."
                }
            }
        }
    }

    func restart() {
        stop()
        requestPermissionsThenStart()
    }

    func toggleRecording() {
        if isRecording {
            pendingManualRecordingRequest = false
            stopRecordingIfNeeded(reason: "Finishing clip...")
        } else {
            guard canRecord else {
                pendingManualRecordingRequest = true
                detailText = "Camera is still starting. Recording will begin when video and audio are ready."
                if !didConfigureSession && !isRunning && !isStartingSession {
                    requestPermissionsThenStart()
                }
                return
            }

            startRecording(triggeredByAutoSpeed: false)
        }
    }

    func clearSavedClipText() {
        savedClipText = "No clips saved yet."
    }

    func toggleRearLens() {
        guard isUltraWideAvailable else {
            detailText = "Ultra-wide lens is not available on this device."
            return
        }

        guard !isRecording else {
            detailText = "Stop recording before switching rear lens."
            return
        }

        rearLens = rearLens == .wide ? .ultraWide : .wide
    }

    func captureRearPhoto() {
        guard isRunning else {
            alertMessage = "Camera is not running yet."
            showAlert = true
            return
        }

        captureQueue.async {
            self.pendingRearPhotoCaptureCount += 1
        }

        detailText = isRecording ? "Saving rear photo from the live recording feed..." : "Saving rear photo..."
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isSceneActive = true
            locationManager.start()
            updateCurrentAngles()
            evaluateAutoStartStop(with: locationManager.speedMetersPerSecond)
        default:
            saveSettings()
            isSceneActive = false
            pendingManualRecordingRequest = false
            resetCaptureReadiness(includeAudio: audioInput != nil)
            locationManager.stop()
            if isRecording {
                stopRecordingIfNeeded(reason: "Stopped because the app left the foreground.")
            }
        }
    }

    private func handleSpeedUpdate(_ speedMetersPerSecond: Double?) {
        updateLiveStampText()
        updateSpeedStatusText(with: speedMetersPerSecond)
        evaluateAutoStartStop(with: speedMetersPerSecond)
    }

    private func handleAutoStartToggleChange() {
        resetAutoSpeedCounters()
        updateSpeedStatusText(with: locationManager.speedMetersPerSecond)

        if !autoStartBySpeed && isAutoSpeedRecording {
            stopRecordingIfNeeded(reason: "Auto start by speed turned off.")
        }
    }

    private func evaluateAutoStartStop(with speedMetersPerSecond: Double?) {
        guard isSceneActive else { return }
        guard autoStartBySpeed else { return }
        guard let speedMetersPerSecond else { return }

        let currentMPH = max(0, speedMetersPerSecond * 2.2369362921)
        let startThreshold = autoStartThresholdMPH
        let stopThreshold = max(1, autoStartThresholdMPH - 2)

        if currentMPH >= startThreshold {
            consecutiveAboveThresholdCount += 1
            consecutiveBelowThresholdCount = 0

            if !isRecording && consecutiveAboveThresholdCount >= 2 {
                startRecording(triggeredByAutoSpeed: true)
            }
        } else if currentMPH <= stopThreshold {
            consecutiveBelowThresholdCount += 1
            consecutiveAboveThresholdCount = 0

            if isRecording && isAutoSpeedRecording && consecutiveBelowThresholdCount >= 3 {
                stopRecordingIfNeeded(reason: "Auto stopped below speed threshold.")
            }
        } else {
            consecutiveAboveThresholdCount = 0
            consecutiveBelowThresholdCount = 0
        }
    }

    private func resetAutoSpeedCounters() {
        consecutiveAboveThresholdCount = 0
        consecutiveBelowThresholdCount = 0
    }

    private func speedText(for speedMetersPerSecond: Double?) -> String {
        let mph = max(0, (speedMetersPerSecond ?? 0) * 2.2369362921)
        return String(format: "%.1f mph", mph)
    }

    private func updateSpeedStatusText(with speedMetersPerSecond: Double?) {
        let speedText = speedText(for: speedMetersPerSecond)

        if autoStartBySpeed {
            speedStatusText = "Speed \(speedText) • auto start at \(Int(autoStartThresholdMPH)) mph"
        } else {
            speedStatusText = "Speed \(speedText) • auto start off"
        }
    }

    // pending record start

    // if the user taps record before the capture session finishes starting,
    // keep that intent and start as soon as the camera is actually live.

    func runPendingManualRecordingRequestIfNeeded() {
        guard pendingManualRecordingRequest else { return }
        guard canRecord else { return }
        guard !isRecording else {
            pendingManualRecordingRequest = false
            return
        }

        pendingManualRecordingRequest = false
        startRecording(triggeredByAutoSpeed: false)
    }

    // capture readiness

    // running the session is not the same as having a usable frame yet
    // use a short warm-up threshold so the very first recording is stable

    func markCaptureReadyIfNeeded() {
        rearWarmupFrameCount += 1
        guard !isCaptureReady else { return }
        guard rearWarmupFrameCount >= rearWarmupFramesRequired else { return }

        DispatchQueue.main.async {
            guard !self.isCaptureReady else { return }
            self.isCaptureReady = true
            if self.audioInput != nil {
                self.prepareAudioSession()
            }
            self.runPendingManualRecordingRequestIfNeeded()
        }
    }

    func markAudioReadyIfNeeded() {
        audioWarmupSampleCount += 1
        guard !isAudioReady else { return }
        guard audioWarmupSampleCount >= audioWarmupSamplesRequired else { return }

        DispatchQueue.main.async {
            guard !self.isAudioReady else { return }
            self.isAudioReady = true
            self.runPendingManualRecordingRequestIfNeeded()
        }
    }

    // readiness reset

    // whenever we restart or rebuild capture, clear warm-up counters
    // so readiness is re-established from fresh live samples.

    func resetCaptureReadiness(includeAudio: Bool) {
        rearWarmupFrameCount = 0
        audioWarmupSampleCount = 0
        isCaptureReady = false
        isAudioReady = !includeAudio
    }

    // rear lens switch

    // switching physical lenses needs a full capture graph rebuild.
    // we keep the same session object and rebuild inputs/outputs in place.

    func applyRearLensChangeIfNeeded() {
        guard didConfigureSession else { return }

        let includeAudio = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        detailText = "Switching rear lens to \(rearLens.label)..."
        pendingManualRecordingRequest = false
        resetCaptureReadiness(includeAudio: includeAudio)
        hasPreparedAudioSession = false

        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }

            self.teardownCaptureGraph()
            self.didConfigureSession = false
            self.hasAttachedPreviewConnection = false

            DispatchQueue.main.async {
                self.isRunning = false
            }

            self.configureIfNeededAndRun(includeAudio: includeAudio)
        }
    }

    func teardownCaptureGraph() {
        session.beginConfiguration()

        if let multiSession = session as? AVCaptureMultiCamSession {
            for connection in multiSession.connections {
                multiSession.removeConnection(connection)
            }
        }

        for output in session.outputs {
            session.removeOutput(output)
        }

        for input in session.inputs {
            session.removeInput(input)
        }

        session.commitConfiguration()

        rearVideoInput = nil
        frontVideoInput = nil
        audioInput = nil
        latestFrontPixelBuffer = nil

        DispatchQueue.main.async {
            self.frontPreviewImage = nil
        }
    }

    // clock and gps

    private func startLiveClock() {
        updateClockText()
        liveClockTimer?.invalidate()
        liveClockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateClockText()
        }
    }

    private func updateClockText() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        currentClockText = formatter.string(from: Date())
        updateLiveStampText()
    }

    private func updateLiveStampText() {
        let gps = locationManager.coordinateText
        let speed = speedText(for: locationManager.speedMetersPerSecond)
        let stampParts = [currentClockText, gps, speed].filter { !$0.isEmpty }
        liveStampText = stampParts.joined(separator: " • ")
        cachedStampKey = ""
        cachedStampOverlay = nil
    }

    // recording

    // recording works as a rolling series of short segments

    // every time one segment closes, storage cleanup runs and deletes the oldest finished files until we are back under the cap

    private func startRecording(triggeredByAutoSpeed: Bool) {
        captureQueue.async {
            guard self.canRecord else {
                if !triggeredByAutoSpeed {
                    self.pendingManualRecordingRequest = true
                    DispatchQueue.main.async {
                        self.detailText = "Camera is still starting. Recording will begin when the first frame is ready."
                    }
                }
                return
            }

            guard self.activeLoopRecording == nil else { return }

            do {
                let folderURL = try Self.clipsFolderURL()
                let loop = ActiveLoopRecording(
                    folderURL: folderURL,
                    sessionID: self.recordingTimestampString(),
                    rearAngle: self.rearCaptureAngle,
                    frontAngle: self.frontCaptureAngle
                )

                try self.startNextSegment(in: loop)
                self.installSegmentTimer(for: loop)
                self.activeLoopRecording = loop
                self.isAutoSpeedRecording = triggeredByAutoSpeed

                DispatchQueue.main.async {
                    self.isRecording = true
                    if self.quality == .p4K {
                        self.detailText = self.recordingMode == .pipSingleFile ? "Loop recording 4K rear clips with front PiP at \(self.frameRate.rawValue) fps..." : "Loop recording 4K rear and front clips at \(self.frameRate.rawValue) fps..."
                    } else {
                        self.detailText = self.recordingMode == .pipSingleFile ? "Loop recording PiP clips..." : "Loop recording rear and front clips..."
                    }
                    self.refreshLoopStatusText()
                }
            } catch {
                DispatchQueue.main.async {
                    self.alertMessage = error.localizedDescription
                    self.detailText = error.localizedDescription
                    self.showAlert = true
                }
            }
        }
    }

    private func stopRecordingIfNeeded(reason: String) {
        captureQueue.async {
            guard let loop = self.activeLoopRecording else { return }
            self.activeLoopRecording = nil
            self.isAutoSpeedRecording = false
            self.resetAutoSpeedCounters()
            loop.segmentTimer?.cancel()
            loop.segmentTimer = nil

            let finalSegment = loop.currentSegment
            loop.currentSegment = nil

            DispatchQueue.main.async {
                self.detailText = reason
                self.isRecording = false
            }

            if let finalSegment {
                self.finishSegment(finalSegment, isFinalStop: true)
            }
        }
    }

    private func installSegmentTimer(for loop: ActiveLoopRecording) {
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + clipLength.seconds, repeating: clipLength.seconds)
        timer.setEventHandler { [weak self, weak loop] in
            guard let self, let loop, let active = self.activeLoopRecording, active === loop else { return }
            self.rotateToNextSegment(for: loop)
        }
        loop.segmentTimer = timer
        timer.resume()
    }

    private func restartLoopTimerIfNeeded() {
        captureQueue.async {
            guard let loop = self.activeLoopRecording else { return }
            loop.segmentTimer?.cancel()
            loop.segmentTimer = nil
            self.installSegmentTimer(for: loop)
        }
    }

    private func rotateToNextSegment(for loop: ActiveLoopRecording) {
        let previousSegment = loop.currentSegment

        do {
            try startNextSegment(in: loop)

            if let previousSegment {
                finishSegment(previousSegment, isFinalStop: false)
            }

            DispatchQueue.main.async {
                self.detailText = "Loop recording segment \(loop.segmentIndex)..."
            }
        } catch {
            DispatchQueue.main.async {
                self.alertMessage = error.localizedDescription
                self.detailText = "Could not rotate to the next clip segment."
                self.showAlert = true
            }
        }
    }

    private func startNextSegment(in loop: ActiveLoopRecording) throws {
        loop.segmentIndex += 1
        loop.currentSegment = try makeRecordingBundle(
            folderURL: loop.folderURL,
            sessionID: loop.sessionID,
            segmentIndex: loop.segmentIndex,
            rearAngle: loop.rearAngle,
            frontAngle: loop.frontAngle
        )
    }

    private func finishSegment(_ recording: ActiveRecording, isFinalStop: Bool) {
        let writers = recording.writers
        let urls = writers.map(\.url)
        let group = DispatchGroup()

        for writer in writers {
            group.enter()
            writer.finish {
                group.leave()
            }
        }

        group.notify(queue: captureQueue) {
            self.trimStorageIfNeeded(protecting: self.currentSegmentProtectedURLs())

            DispatchQueue.main.async {
                self.savedClipText = urls.map(\.lastPathComponent).joined(separator: " • ")
                self.refreshLoopStatusText()
                self.detailText = isFinalStop ? "Final loop clip saved locally." : "Loop clip rotated and saved locally."
            }
        }
    }

    private func makeRecordingBundle(folderURL: URL, sessionID: String, segmentIndex: Int, rearAngle: CGFloat, frontAngle: CGFloat) throws -> ActiveRecording {
        let rearCanvas = quality.size
        let frontQuality = frontTargetQuality
        let frontCanvas = frontQuality.size
        let audioEnabled = audioInput != nil
        let segmentString = String(format: "%03d", segmentIndex)
        let includeFrontInPiP = showFrontPreview

        switch recordingMode {
        case .pipSingleFile:
            let comboURL = folderURL.appendingPathComponent("DashCam_\(sessionID)_segment_\(segmentString)_combo.mov")
            let comboWriter = try RecordingWriter(
                url: comboURL,
                canvasSize: rearCanvas,
                quality: quality,
                includeAudio: audioEnabled,
                bitRateOverride: adjustedBitrate(for: quality)
            )
            return ActiveRecording(mode: .pipSingleFile, primaryWriter: comboWriter, secondaryWriter: nil, rearAngle: rearAngle, frontAngle: frontAngle, includeFrontInPiP: includeFrontInPiP)

        case .dualSeparateFiles:
            let rearURL = folderURL.appendingPathComponent("DashCam_\(sessionID)_segment_\(segmentString)_rear.mov")
            let frontURL = folderURL.appendingPathComponent("DashCam_\(sessionID)_segment_\(segmentString)_front.mov")
            let rearWriter = try RecordingWriter(
                url: rearURL,
                canvasSize: rearCanvas,
                quality: quality,
                includeAudio: audioEnabled,
                bitRateOverride: adjustedBitrate(for: quality)
            )
            let frontWriter = try RecordingWriter(
                url: frontURL,
                canvasSize: frontCanvas,
                quality: frontQuality,
                includeAudio: audioEnabled,
                bitRateOverride: adjustedBitrate(for: frontQuality)
            )

            if !burnStamp {
                rearWriter.setVideoTransform(transformForRotationAngle(rearAngle, canvasSize: rearCanvas))
                if multiCamSupported {
                    frontWriter.setVideoTransform(transformForRotationAngle(frontAngle, canvasSize: frontCanvas))
                }
            }

            return ActiveRecording(mode: .dualSeparateFiles, primaryWriter: rearWriter, secondaryWriter: multiCamSupported ? frontWriter : nil, rearAngle: rearAngle, frontAngle: frontAngle, includeFrontInPiP: true)
        }
    }

    private func currentSegmentProtectedURLs() -> Set<URL> {
        guard let currentSegment = activeLoopRecording?.currentSegment else { return [] }
        return Set(currentSegment.writers.map(\.url))
    }

    private func trimStorageIfNeeded(protecting protectedURLs: Set<URL>) {
        guard let folderURL = try? Self.clipsFolderURL() else { return }

        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: Array(resourceKeys)) else { return }

        var entries: [(url: URL, date: Date, size: Int64)] = []
        var totalSize: Int64 = 0

        for url in urls where url.pathExtension.lowercased() == "mov" {
            let values = try? url.resourceValues(forKeys: resourceKeys)
            guard values?.isRegularFile == true else { continue }
            let size = Int64(values?.fileSize ?? 0)
            let date = values?.contentModificationDate ?? .distantPast
            totalSize += size

            if !protectedURLs.contains(url) {
                entries.append((url: url, date: date, size: size))
            }
        }

        guard totalSize > storageCap.bytes else { return }

        let sorted = entries.sorted { $0.date < $1.date }
        var runningSize = totalSize

        for entry in sorted where runningSize > storageCap.bytes {
            do {
                try FileManager.default.removeItem(at: entry.url)
                runningSize -= entry.size
            } catch {
                continue
            }
        }
    }

    func refreshLoopStatusText() {
        let folderURL = try? Self.clipsFolderURL()
        let usedBytes = folderURL.map(localStorageBytes(in:)) ?? 0
        let usedText = ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)
        loopStatusText = "Loop \(clipLength.shortLabel) • cap \(storageCap.shortLabel) • used \(usedText)"
    }

    private func localStorageBytes(in folderURL: URL) -> Int64 {
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: Array(resourceKeys)) else {
            return 0
        }

        var total: Int64 = 0
        for url in urls where url.pathExtension.lowercased() == "mov" {
            let values = try? url.resourceValues(forKeys: resourceKeys)
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

}

// recording writer

// each output file gets its own writer so the controller only has to think about routing and mode
