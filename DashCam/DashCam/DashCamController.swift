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
        static let quality = "dashcam.quality"
        static let clipLength = "dashcam.clipLength"
        static let storageCap = "dashcam.storageCap"
        static let frameRate = "dashcam.frameRate"
        static let burnStamp = "dashcam.burnStamp"
        static let showFrontPreview = "dashcam.showFrontPreview"
        static let showCompass = "dashcam.showCompass"
        static let showMainStatusBadges = "dashcam.showMainStatusBadges"
        static let showMainExtraInfo = "dashcam.showMainExtraInfo"
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
    @Published var quality: DashVideoQuality = DashCamController.savedQuality() {
        didSet {
            guard quality != oldValue else { return }
            saveSettings()
            refreshLoopStatusText()
            applyCurrentCaptureFormatsIfPossible()
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

    private let sessionQueue = DispatchQueue(label: "dashcam.session.queue")
    private let captureQueue = DispatchQueue(label: "dashcam.capture.queue")
    private let frontPreviewQueue = DispatchQueue(label: "dashcam.front.preview.queue")
    private let ciContext = CIContext(options: nil)
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let multiSessionSupported: Bool = AVCaptureMultiCamSession.isMultiCamSupported
    private var didConfigureSession: Bool = false
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasAttachedPreviewConnection: Bool = false
    private var liveClockTimer: Timer?
    private var currentClockText: String = ""
    private var cancellables = Set<AnyCancellable>()
    private var orientationObserver: NSObjectProtocol?

    private var rearVideoInput: AVCaptureDeviceInput?
    private var frontVideoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?

    private let rearVideoOutput = AVCaptureVideoDataOutput()
    private let frontVideoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    private var latestFrontPixelBuffer: CVPixelBuffer?
    private var lastFrontPreviewPush: CFTimeInterval = 0
    private var isFrontPreviewRenderInFlight: Bool = false
    private var activeLoopRecording: ActiveLoopRecording?
    private var isSceneActive: Bool = true
    private var consecutiveAboveThresholdCount: Int = 0
    private var consecutiveBelowThresholdCount: Int = 0
    private var isAutoSpeedRecording: Bool = false
    private var pendingRearPhotoCaptureCount: Int = 0
    private let frontPreviewTargetSize = CGSize(width: 320, height: 420)
    private let frontPreviewTargetSizeAt60FPS = CGSize(width: 220, height: 300)

    // cached stamp overlay

    // text only changes once a second so build the overlay once and reuse it instead of redrawing it every frame

    private var cachedStampKey: String = ""
    private var cachedStampOverlay: CIImage?

    // rotation state

    // preview updates live

    // each active clip freezes the current angles at the moment recording starts

    private var rearPreviewAngle: CGFloat = 0
    private var rearCaptureAngle: CGFloat = 0
    private var frontCaptureAngle: CGFloat = 0

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

    private func recordingTimestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }

    private func photoTimestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss_SSS"
        return formatter.string(from: Date())
    }

    private func photosFolderURL() throws -> URL {
        let folderURL = try Self.clipsFolderURL().appendingPathComponent("Snapshots", isDirectory: true)

        if !FileManager.default.fileExists(atPath: folderURL.path) {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        }

        return folderURL
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(recordingMode.rawValue, forKey: SavedSettingKey.recordingMode)
        defaults.set(quality.rawValue, forKey: SavedSettingKey.quality)
        defaults.set(clipLength.rawValue, forKey: SavedSettingKey.clipLength)
        defaults.set(storageCap.rawValue, forKey: SavedSettingKey.storageCap)
        defaults.set(frameRate.rawValue, forKey: SavedSettingKey.frameRate)
        defaults.set(burnStamp, forKey: SavedSettingKey.burnStamp)
        defaults.set(showFrontPreview, forKey: SavedSettingKey.showFrontPreview)
        defaults.set(showCompass, forKey: SavedSettingKey.showCompass)
        defaults.set(showMainStatusBadges, forKey: SavedSettingKey.showMainStatusBadges)
        defaults.set(showMainExtraInfo, forKey: SavedSettingKey.showMainExtraInfo)
        defaults.set(autoStartBySpeed, forKey: SavedSettingKey.autoStartBySpeed)
        defaults.set(autoStartThresholdMPH, forKey: SavedSettingKey.autoStartThresholdMPH)
        defaults.synchronize()
    }

    var multiCamSupported: Bool {
        multiSessionSupported
    }

    private var targetFrameRate: Double {
        frameRate.framesPerSecond
    }

    var compassText: String? {
        guard let heading = locationManager.headingDegrees else { return nil }
        let normalized = Int(round(heading)).quotientAndRemainder(dividingBy: 360).remainder
        let positive = normalized >= 0 ? normalized : normalized + 360
        return "\(headingDirection(for: positive)) \(positive)°"
    }

    private func headingDirection(for heading: Int) -> String {
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
        isRunning
    }

    func start() {
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
            stopRecordingIfNeeded(reason: "Finishing clip...")
        } else {
            startRecording(triggeredByAutoSpeed: false)
        }
    }

    func clearSavedClipText() {
        savedClipText = "No clips saved yet."
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

    // preview hookup

    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        sessionQueue.async {
            self.previewLayer = layer
            layer.videoGravity = .resizeAspectFill

            if self.multiCamSupported {
                self.attachMultiCamPreviewIfNeeded(to: layer)
            } else {
                if layer.session !== self.session {
                    layer.session = self.session
                }
            }

            self.applyPreviewMirrorState(to: layer.connection)
            DispatchQueue.main.async {
                self.applyPreviewRotationNow()
            }
        }
    }

    // permissions

    private func requestPermissionsThenStart() {
        let videoStatus = AVCaptureDevice.authorizationStatus(for: .video)

        switch videoStatus {
        case .authorized:
            requestAudioThenConfigure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.requestAudioThenConfigure()
                    } else {
                        self.alertMessage = "Camera permission is required."
                        self.detailText = "Camera permission denied."
                        self.showAlert = true
                    }
                }
            }
        default:
            alertMessage = "Camera permission is required."
            detailText = "Camera permission denied."
            showAlert = true
        }
    }

    private func requestAudioThenConfigure() {
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        switch audioStatus {
        case .authorized:
            configureIfNeededAndRun(includeAudio: true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.configureIfNeededAndRun(includeAudio: granted)
                }
            }
        default:
            configureIfNeededAndRun(includeAudio: false)
        }
    }

    private func configureIfNeededAndRun(includeAudio: Bool) {
        sessionQueue.async {
            do {
                if !self.didConfigureSession {
                    try self.configureSession(includeAudio: includeAudio)
                    self.didConfigureSession = true
                }

                if includeAudio {
                    self.prepareAudioSession()
                }

                if !self.session.isRunning {
                    self.session.startRunning()
                }

                self.attachPreviewIfPossible()

                DispatchQueue.main.async {
                    self.isRunning = self.session.isRunning
                    self.detailText = self.multiCamSupported ? "Rear preview live. Ready for PiP or dual-file recording." : "Rear preview live. MultiCam not supported on this device."
                    self.refreshLoopStatusText()
                    self.applyPreviewRotationNow()
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

    private func prepareAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
            try audioSession.setActive(true)
        } catch {
            DispatchQueue.main.async {
                self.savedClipText = "Mic session warning: \(error.localizedDescription)"
            }
        }
    }

    // session setup

    private func configureSession(includeAudio: Bool) throws {
        if multiCamSupported {
            try configureMultiCamSession(includeAudio: includeAudio)
        } else {
            try configureSingleCamSession(includeAudio: includeAudio)
        }
    }

    private func configureMultiCamSession(includeAudio: Bool) throws {
        guard let multiSession = session as? AVCaptureMultiCamSession else {
            throw DashCamError.couldNotCreateMultiCamSession
        }

        multiSession.beginConfiguration()
        defer { multiSession.commitConfiguration() }

        guard let rearDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw DashCamError.noRearCamera
        }

        guard let frontDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw DashCamError.noFrontCamera
        }

        let rearMaxWidth = quality.usesRearOnly4KBehavior ? Int32(quality.size.width) : Int32(quality.size.width)
        let frontMaxWidth = quality.frontCompanionQuality.size.width

        try setMultiCamFormatIfPossible(for: rearDevice, maxWidth: rearMaxWidth)
        try setMultiCamFormatIfPossible(for: frontDevice, maxWidth: Int32(frontMaxWidth))

        let rearInput = try AVCaptureDeviceInput(device: rearDevice)
        let frontInput = try AVCaptureDeviceInput(device: frontDevice)

        guard multiSession.canAddInput(rearInput), multiSession.canAddInput(frontInput) else {
            throw DashCamError.couldNotAddInput
        }

        multiSession.addInputWithNoConnections(rearInput)
        multiSession.addInputWithNoConnections(frontInput)
        self.rearVideoInput = rearInput
        self.frontVideoInput = frontInput

        configureVideoOutput(rearVideoOutput)
        configureVideoOutput(frontVideoOutput)

        guard multiSession.canAddOutput(rearVideoOutput), multiSession.canAddOutput(frontVideoOutput) else {
            throw DashCamError.couldNotAddVideoOutput
        }

        multiSession.addOutputWithNoConnections(rearVideoOutput)
        multiSession.addOutputWithNoConnections(frontVideoOutput)

        guard let rearPort = rearInput.ports.first(where: { $0.mediaType == .video }),
              let frontPort = frontInput.ports.first(where: { $0.mediaType == .video }) else {
            throw DashCamError.couldNotAddInput
        }

        let rearVideoConnection = AVCaptureConnection(inputPorts: [rearPort], output: rearVideoOutput)
        let frontVideoConnection = AVCaptureConnection(inputPorts: [frontPort], output: frontVideoOutput)

        guard multiSession.canAddConnection(rearVideoConnection), multiSession.canAddConnection(frontVideoConnection) else {
            throw DashCamError.couldNotAddConnection
        }

        multiSession.addConnection(rearVideoConnection)
        multiSession.addConnection(frontVideoConnection)

        if frontVideoConnection.isVideoMirroringSupported {
            frontVideoConnection.automaticallyAdjustsVideoMirroring = false
            frontVideoConnection.isVideoMirrored = false
        }

        if includeAudio, let micDevice = AVCaptureDevice.default(for: .audio) {
            let audioInput = try AVCaptureDeviceInput(device: micDevice)
            if multiSession.canAddInput(audioInput) {
                multiSession.addInputWithNoConnections(audioInput)
                self.audioInput = audioInput

                audioOutput.setSampleBufferDelegate(self, queue: captureQueue)

                if multiSession.canAddOutput(audioOutput) {
                    multiSession.addOutputWithNoConnections(audioOutput)

                    if let audioPort = audioInput.ports.first(where: { $0.mediaType == .audio }) {
                        let audioConnection = AVCaptureConnection(inputPorts: [audioPort], output: audioOutput)
                        if multiSession.canAddConnection(audioConnection) {
                            multiSession.addConnection(audioConnection)
                        }
                    }
                }
            }
        }
    }

    private func configureSingleCamSession(includeAudio: Bool) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard let rearDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw DashCamError.noRearCamera
        }

        try setSingleCamFormatIfPossible(for: rearDevice, maxWidth: Int32(quality.size.width))

        let rearInput = try AVCaptureDeviceInput(device: rearDevice)
        guard session.canAddInput(rearInput) else {
            throw DashCamError.couldNotAddInput
        }

        session.addInput(rearInput)
        self.rearVideoInput = rearInput

        configureVideoOutput(rearVideoOutput)
        guard session.canAddOutput(rearVideoOutput) else {
            throw DashCamError.couldNotAddVideoOutput
        }
        session.addOutput(rearVideoOutput)

        if includeAudio, let micDevice = AVCaptureDevice.default(for: .audio) {
            let audioInput = try AVCaptureDeviceInput(device: micDevice)
            if session.canAddInput(audioInput) {
                session.addInput(audioInput)
                self.audioInput = audioInput
            }

            audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
            }
        }
    }

    private func configureVideoOutput(_ output: AVCaptureVideoDataOutput) {
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)
    }

    // preview connection

    private func attachPreviewIfPossible() {
        guard let previewLayer else { return }

        if multiCamSupported {
            attachMultiCamPreviewIfNeeded(to: previewLayer)
        } else {
            if previewLayer.session !== session {
                previewLayer.session = session
            }
        }

        applyPreviewMirrorState(to: previewLayer.connection)
        DispatchQueue.main.async {
            self.applyPreviewRotationNow()
        }
    }

    private func attachMultiCamPreviewIfNeeded(to layer: AVCaptureVideoPreviewLayer) {
        guard let multiSession = session as? AVCaptureMultiCamSession else { return }

        if layer.session !== multiSession {
            layer.session = multiSession
        }

        guard !hasAttachedPreviewConnection else { return }

        guard let rearPort = rearVideoInput?.ports.first(where: {
            $0.mediaType == .video && $0.sourceDevicePosition == .back
        }) else {
            return
        }

        let previewConnection = AVCaptureConnection(inputPort: rearPort, videoPreviewLayer: layer)

        guard multiSession.canAddConnection(previewConnection) else { return }
        multiSession.addConnection(previewConnection)
        hasAttachedPreviewConnection = true
    }

    private func applyPreviewMirrorState(to connection: AVCaptureConnection?) {
        guard let connection else { return }

        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    private func applyPreviewRotationNow() {
        guard let connection = previewLayer?.connection else { return }
        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(rearPreviewAngle) {
                connection.videoRotationAngle = rearPreviewAngle
            }
        }
    }

    // orientation tracking

    // the preview updates whenever the interface or device rotates

    // recording freezes whatever the current angles are when the user presses record

    private func startOrientationTracking() {
        updateCurrentAngles()

        if orientationObserver == nil {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            orientationObserver = NotificationCenter.default.addObserver(
                forName: UIDevice.orientationDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.updateCurrentAngles()
            }
        }
    }

    private func updateCurrentAngles() {
        let orientation = currentInterfaceOrDeviceOrientation()
        let angles = anglesForOrientation(orientation)
        rearPreviewAngle = angles.preview
        rearCaptureAngle = angles.rearCapture
        frontCaptureAngle = angles.frontCapture
        applyPreviewRotationNow()
    }

    private func currentInterfaceOrDeviceOrientation() -> UIInterfaceOrientation {
        switch UIDevice.current.orientation {
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .portrait:
            return .portrait
        default:
            return .portrait
        }
    }

    private func anglesForOrientation(_ orientation: UIInterfaceOrientation) -> (preview: CGFloat, rearCapture: CGFloat, frontCapture: CGFloat) {
        let baseAngle: CGFloat

        switch orientation {
        case .landscapeLeft:
            baseAngle = 180
        case .landscapeRight:
            baseAngle = 0
        case .portraitUpsideDown:
            baseAngle = 270
        case .portrait:
            baseAngle = 90
        default:
            baseAngle = 0
        }

        // keep the preview on the original angle path because that was already
        // rendering correctly on screen. only the saved rear output needs the
        // portrait-only correction.
        let previewAngle = normalizedAngle(baseAngle)

        // the rear recording is correct in landscape with the plain base angle,
        // but on this device family portrait needs the opposite right-angle.
        // keep the existing landscape behavior and only flip the rear capture
        // mapping for the two portrait cases.
        let rearCaptureAngle: CGFloat

        switch orientation {
        case .portrait, .portraitUpsideDown:
            rearCaptureAngle = normalizedAngle(baseAngle + 180)
        default:
            rearCaptureAngle = normalizedAngle(baseAngle)
        }

        let frontAngle = normalizedAngle(baseAngle + 180)

        return (previewAngle, rearCaptureAngle, frontAngle)
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
            guard self.session.isRunning else {
                DispatchQueue.main.async {
                    self.alertMessage = "Camera is not running yet."
                    self.detailText = "Wait for the camera to finish starting."
                    self.showAlert = true
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
        let frontQuality = quality.frontCompanionQuality
        let frontCanvas = frontQuality.size
        let audioEnabled = audioInput != nil
        let segmentString = String(format: "%03d", segmentIndex)
        let includeFrontInPiP = showFrontPreview

        switch recordingMode {
        case .pipSingleFile:
            let comboURL = folderURL.appendingPathComponent("DashCam_\(sessionID)_segment_\(segmentString)_combo.mov")
            let comboWriter = try RecordingWriter(url: comboURL, canvasSize: rearCanvas, quality: quality, includeAudio: audioEnabled)
            return ActiveRecording(mode: .pipSingleFile, primaryWriter: comboWriter, secondaryWriter: nil, rearAngle: rearAngle, frontAngle: frontAngle, includeFrontInPiP: includeFrontInPiP)

        case .dualSeparateFiles:
            let rearURL = folderURL.appendingPathComponent("DashCam_\(sessionID)_segment_\(segmentString)_rear.mov")
            let frontURL = folderURL.appendingPathComponent("DashCam_\(sessionID)_segment_\(segmentString)_front.mov")
            let rearWriter = try RecordingWriter(url: rearURL, canvasSize: rearCanvas, quality: quality, includeAudio: audioEnabled)
            let frontWriter = try RecordingWriter(url: frontURL, canvasSize: frontCanvas, quality: frontQuality, includeAudio: audioEnabled)

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

    private func refreshLoopStatusText() {
        let folderURL = try? Self.clipsFolderURL()
        let usedBytes = folderURL.map(localStorageBytes(in:)) ?? 0
        let usedText = ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)
        loopStatusText = "Loop \(clipLength.shortLabel) • cap \(storageCap.shortLabel) • used \(usedText)"
    }

    private func applyCurrentCaptureFormatsIfPossible() {
        sessionQueue.async {
            guard self.didConfigureSession else { return }

            do {
                if let rearDevice = self.rearVideoInput?.device {
                    if self.multiCamSupported {
                        try self.setMultiCamFormatIfPossible(for: rearDevice, maxWidth: Int32(self.quality.size.width))
                    } else {
                        try self.setSingleCamFormatIfPossible(for: rearDevice, maxWidth: Int32(self.quality.size.width))
                    }
                }

                if self.multiCamSupported, let frontDevice = self.frontVideoInput?.device {
                    try self.setMultiCamFormatIfPossible(for: frontDevice, maxWidth: Int32(self.quality.frontCompanionQuality.size.width))
                }

                DispatchQueue.main.async {
                    self.detailText = self.quality == .p4K ? "4K rear mode ready. Front PiP stays on if enabled. Capture is capped to \(self.frameRate.rawValue) fps." : "Capture quality updated. Both cameras capped to \(self.frameRate.rawValue) fps."
                }
            } catch {
                DispatchQueue.main.async {
                    self.detailText = "Could not apply the new capture format."
                    self.alertMessage = error.localizedDescription
                    self.showAlert = true
                }
            }
        }
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

    // device format

    private func setMultiCamFormatIfPossible(for device: AVCaptureDevice, maxWidth: Int32) throws {
        let supported = device.formats
            .filter { format in
                format.isMultiCamSupported && format.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= targetFrameRate })
            }
            .sorted {
                let left = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                let right = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
                return left.width < right.width
            }

        guard let chosen = supported.last(where: { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <= maxWidth }) ?? supported.last else {
            return
        }

        try device.lockForConfiguration()
        device.activeFormat = chosen
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFrameRate))
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        device.unlockForConfiguration()
    }

    private func setSingleCamFormatIfPossible(for device: AVCaptureDevice, maxWidth: Int32) throws {
        let supported = device.formats
            .filter { format in
                format.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= targetFrameRate })
            }
            .sorted {
                let left = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                let right = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
                return left.width < right.width
            }

        guard let chosen = supported.last(where: { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <= maxWidth }) ?? supported.last else {
            return
        }

        try device.lockForConfiguration()
        device.activeFormat = chosen
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFrameRate))
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        device.unlockForConfiguration()
    }

    // front preview image

    // this is a lightweight thumbnail path, not the real rear preview path

    private var frontPreviewMinimumInterval: CFTimeInterval {
        if isRecording && frameRate == .fps60 {
            return 0.12
        }

        return isRecording ? 0.08 : 0.06
    }

    private var currentFrontPreviewTargetSize: CGSize {
        if isRecording && frameRate == .fps60 {
            return frontPreviewTargetSizeAt60FPS
        }

        return frontPreviewTargetSize
    }

    private func shouldQueueFrontPreviewNow() -> Bool {
        guard showFrontPreview else { return false }
        guard !isFrontPreviewRenderInFlight else { return false }

        let now = CACurrentMediaTime()
        return now - lastFrontPreviewPush > frontPreviewMinimumInterval
    }

    private func queueFrontPreviewImage(from pixelBuffer: CVPixelBuffer, angle: CGFloat) {
        guard showFrontPreview else { return }

        let now = CACurrentMediaTime()

        guard now - lastFrontPreviewPush > frontPreviewMinimumInterval else { return }
        guard !isFrontPreviewRenderInFlight else { return }
        lastFrontPreviewPush = now
        isFrontPreviewRenderInFlight = true

        frontPreviewQueue.async { [weak self] in
            guard let self else { return }

            let image = self.makeUIImage(
                from: pixelBuffer,
                applyingRotationAngle: angle,
                mirrored: true,
                targetSize: self.currentFrontPreviewTargetSize
            )

            DispatchQueue.main.async {
                self.frontPreviewImage = image
            }

            self.captureQueue.async {
                self.isFrontPreviewRenderInFlight = false
            }
        }
    }

    private func makeUIImage(
        from pixelBuffer: CVPixelBuffer,
        applyingRotationAngle angle: CGFloat,
        mirrored: Bool,
        targetSize: CGSize? = nil
    ) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let rotated = applyDiscreteRotation(angle: angle, to: ciImage)
        let finalImage = mirrored ? applyHorizontalMirror(to: rotated) : rotated
        let outputImage: CIImage

        if let targetSize {
            let targetRect = CGRect(origin: .zero, size: targetSize)
            outputImage = aspectFillCIImage(finalImage, into: targetRect)
        } else {
            outputImage = finalImage
        }

        guard let cgImage = ciContext.createCGImage(outputImage, from: outputImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    // pixel buffer helpers

    private func copyPixelBuffer(from pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var copy: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]

        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &copy)
        guard status == kCVReturnSuccess, let copy else {
            return nil
        }

        ciContext.render(CIImage(cvPixelBuffer: pixelBuffer), to: copy)
        return copy
    }

    private func makeWriterPixelBuffer(for writer: RecordingWriter) -> CVPixelBuffer? {
        if let pool = writer.adaptor.pixelBufferPool {
            var buffer: CVPixelBuffer?
            if CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess {
                return buffer
            }
        }

        let width = Int(writer.canvasSize.width)
        let height = Int(writer.canvasSize.height)
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]

        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess else { return nil }
        return buffer
    }

    private func fastPathCanUseSourceBuffer(_ pixelBuffer: CVPixelBuffer, for writer: RecordingWriter) -> Bool {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        return width == Int(writer.canvasSize.width) && height == Int(writer.canvasSize.height) && !burnStamp
    }

    // ciimage rotation and render helpers

    private func renderedPixelBuffer(
        for writer: RecordingWriter,
        source: CVPixelBuffer,
        pip: CVPixelBuffer?,
        includePiP: Bool,
        sourceAngle: CGFloat,
        pipAngle: CGFloat?,
        sourceMirrored: Bool = false,
        pipMirrored: Bool = false
    ) -> CVPixelBuffer? {
        guard let outputBuffer = makeWriterPixelBuffer(for: writer) else { return nil }

        let canvasRect = CGRect(origin: .zero, size: writer.canvasSize)
        var composedImage = CIImage(color: .black).cropped(to: canvasRect)

        let rotatedSource = applyDiscreteRotation(angle: sourceAngle, to: CIImage(cvPixelBuffer: source))
        let sourceImage = sourceMirrored ? applyHorizontalMirror(to: rotatedSource) : rotatedSource
        let rearImage = aspectFillCIImage(sourceImage, into: canvasRect)
        composedImage = rearImage.composited(over: composedImage)

        var pipBorderRect: CGRect?

        if includePiP, let pip, let pipAngle {
            let pipWidth = writer.canvasSize.width * 0.28
            let pipHeight = pipWidth * 0.75
            let pipRect = CGRect(
                x: writer.canvasSize.width - pipWidth - 32,
                y: writer.canvasSize.height - pipHeight - 32,
                width: pipWidth,
                height: pipHeight
            )
            let rotatedPiP = applyDiscreteRotation(angle: pipAngle, to: CIImage(cvPixelBuffer: pip))
            let pipImage = pipMirrored ? applyHorizontalMirror(to: rotatedPiP) : rotatedPiP
            let pipPlaced = aspectFillCIImage(pipImage, into: pipRect)
            composedImage = pipPlaced.composited(over: composedImage)
            pipBorderRect = pipRect
        }

        if burnStamp, let stampOverlay = stampOverlayImage(for: writer.canvasSize) {
            composedImage = stampOverlay.composited(over: composedImage)
        }

        ciContext.render(composedImage, to: outputBuffer, bounds: canvasRect, colorSpace: colorSpace)

        if let pipBorderRect {
            drawOverlay(on: outputBuffer, pipBorderRect: pipBorderRect)
        }

        return outputBuffer
    }

    private func aspectFillCIImage(_ image: CIImage, into rect: CGRect) -> CIImage {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return image.cropped(to: rect) }

        let scale = max(rect.width / extent.width, rect.height / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let translated = scaled.transformed(by: CGAffineTransform(
            translationX: rect.midX - scaled.extent.midX,
            y: rect.midY - scaled.extent.midY
        ))
        return translated.cropped(to: rect)
    }

    private func applyHorizontalMirror(to image: CIImage) -> CIImage {
        let extent = image.extent.integral
        return image.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -extent.width, y: 0))
    }

    private func applyDiscreteRotation(angle: CGFloat, to image: CIImage) -> CIImage {
        let normalized = normalizedRightAngle(angle)
        let extent = image.extent.integral

        switch normalized {
        case 90:
            return image.transformed(by: CGAffineTransform(translationX: extent.height, y: 0).rotated(by: .pi / 2))
        case 180:
            return image.transformed(by: CGAffineTransform(translationX: extent.width, y: extent.height).rotated(by: .pi))
        case 270:
            return image.transformed(by: CGAffineTransform(translationX: 0, y: extent.width).rotated(by: -.pi / 2))
        default:
            return image
        }
    }

    private func normalizedRightAngle(_ angle: CGFloat) -> Int {
        let normalized = Int(round(angle.truncatingRemainder(dividingBy: 360)))
        let positive = normalized >= 0 ? normalized : normalized + 360

        switch positive {
        case 45..<135:
            return 90
        case 135..<225:
            return 180
        case 225..<315:
            return 270
        default:
            return 0
        }
    }

    private func transformForRotationAngle(_ angle: CGFloat, canvasSize: CGSize) -> CGAffineTransform {
        switch normalizedRightAngle(angle) {
        case 90:
            return CGAffineTransform(translationX: canvasSize.height, y: 0).rotated(by: .pi / 2)
        case 180:
            return CGAffineTransform(translationX: canvasSize.width, y: canvasSize.height).rotated(by: .pi)
        case 270:
            return CGAffineTransform(translationX: 0, y: canvasSize.width).rotated(by: -.pi / 2)
        default:
            return .identity
        }
    }

    private func normalizedAngle(_ angle: CGFloat) -> CGFloat {
        let remainder = angle.truncatingRemainder(dividingBy: 360)
        return remainder >= 0 ? remainder : remainder + 360
    }

    private func stampOverlayImage(for canvasSize: CGSize) -> CIImage? {
        let key = "\(Int(canvasSize.width))x\(Int(canvasSize.height))|\(liveStampText)"
        if cachedStampKey == key {
            return cachedStampOverlay
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        let image = renderer.image { _ in
            let padding: CGFloat = 16
            let boxHeight: CGFloat = 42
            let boxRect = CGRect(x: padding, y: padding, width: canvasSize.width - (padding * 2), height: boxHeight)

            UIColor.black.withAlphaComponent(0.58).setFill()
            UIBezierPath(rect: boxRect).fill()

            let font = UIFont.monospacedSystemFont(ofSize: max(14, min(canvasSize.width * 0.018, 28)), weight: .semibold)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            paragraph.lineBreakMode = .byTruncatingMiddle

            let attributed = NSAttributedString(string: liveStampText, attributes: [
                .font: font,
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ])

            attributed.draw(in: boxRect.insetBy(dx: 12, dy: 8))
        }

        let overlay = CIImage(image: image)
        cachedStampKey = key
        cachedStampOverlay = overlay
        return overlay
    }

    private func saveRearPhoto(from pixelBuffer: CVPixelBuffer, angle: CGFloat) {
        let rotatedImage = applyDiscreteRotation(angle: angle, to: CIImage(cvPixelBuffer: pixelBuffer))
        let finalImage: CIImage

        if burnStamp, let overlay = stampOverlayImage(for: rotatedImage.extent.integral.size) {
            finalImage = overlay.composited(over: rotatedImage)
        } else {
            finalImage = rotatedImage
        }

        guard let cgImage = ciContext.createCGImage(finalImage, from: finalImage.extent) else {
            DispatchQueue.main.async {
                self.detailText = "Could not build the rear photo."
            }
            return
        }

        guard let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.9) else {
            DispatchQueue.main.async {
                self.detailText = "Could not encode the rear photo."
            }
            return
        }

        do {
            let folderURL = try photosFolderURL()
            let fileURL = folderURL.appendingPathComponent("DashCam_\(photoTimestampString())_rear.jpg")
            try data.write(to: fileURL, options: .atomic)

            DispatchQueue.main.async {
                self.savedClipText = fileURL.lastPathComponent
                self.detailText = "Rear photo saved locally."
            }
        } catch {
            DispatchQueue.main.async {
                self.alertMessage = error.localizedDescription
                self.detailText = "Could not save the rear photo."
                self.showAlert = true
            }
        }
    }

    private func drawOverlay(on pixelBuffer: CVPixelBuffer, pipBorderRect: CGRect) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return
        }

        context.setStrokeColor(UIColor.white.withAlphaComponent(0.72).cgColor)
        context.setLineWidth(3)
        context.stroke(pipBorderRect)
    }
}

// capture delegates

// every sample buffer callback stays on one serial queue so writer state stays predictable

extension DashCamController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === rearVideoOutput {
            handleRearVideoSample(sampleBuffer)
        } else if output === frontVideoOutput {
            handleFrontVideoSample(sampleBuffer)
        } else if output === audioOutput {
            handleAudioSample(sampleBuffer)
        }
    }

    private func handleRearVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if pendingRearPhotoCaptureCount > 0, let copiedBuffer = copyPixelBuffer(from: imageBuffer) {
            pendingRearPhotoCaptureCount -= 1
            saveRearPhoto(from: copiedBuffer, angle: rearCaptureAngle)
        }

        guard let recording = activeLoopRecording?.currentSegment else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        switch recording.mode {
        case .pipSingleFile:
            let pipBuffer = recording.includeFrontInPiP ? latestFrontPixelBuffer : nil
            guard let rendered = renderedPixelBuffer(
                for: recording.primaryWriter,
                source: imageBuffer,
                pip: pipBuffer,
                includePiP: pipBuffer != nil,
                sourceAngle: recording.rearAngle,
                pipAngle: pipBuffer != nil ? recording.frontAngle : nil,
                pipMirrored: pipBuffer != nil
            ) else {
                return
            }
            recording.primaryWriter.appendVideo(pixelBuffer: rendered, presentationTime: presentationTime)

        case .dualSeparateFiles:
            if !burnStamp && fastPathCanUseSourceBuffer(imageBuffer, for: recording.primaryWriter) {
                recording.primaryWriter.appendVideo(pixelBuffer: imageBuffer, presentationTime: presentationTime)
            } else if let rendered = renderedPixelBuffer(
                for: recording.primaryWriter,
                source: imageBuffer,
                pip: nil,
                includePiP: false,
                sourceAngle: recording.rearAngle,
                pipAngle: nil
            ) {
                recording.primaryWriter.appendVideo(pixelBuffer: rendered, presentationTime: presentationTime)
            }
        }
    }

    private func handleFrontVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard multiCamSupported else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let needsFrontBufferForPiP = recordingMode == .pipSingleFile
        let shouldRefreshFrontPreview = (!isRecording || recordingMode == .pipSingleFile) && shouldQueueFrontPreviewNow()

        // when the combined rear writer needs the latest front frame and the ui
        // also wants a preview refresh, make one copied buffer do both jobs.
        if needsFrontBufferForPiP || shouldRefreshFrontPreview {
            if let copied = copyPixelBuffer(from: imageBuffer) {
                if needsFrontBufferForPiP {
                    latestFrontPixelBuffer = copied
                }

                if shouldRefreshFrontPreview {
                    queueFrontPreviewImage(from: copied, angle: frontCaptureAngle)
                }
            }
        }

        guard let recording = activeLoopRecording?.currentSegment else { return }
        guard recording.mode == .dualSeparateFiles, let frontWriter = recording.secondaryWriter else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if !burnStamp && fastPathCanUseSourceBuffer(imageBuffer, for: frontWriter) {
            frontWriter.appendVideo(pixelBuffer: imageBuffer, presentationTime: presentationTime)
            } else if let rendered = renderedPixelBuffer(
                for: frontWriter,
                source: imageBuffer,
                pip: nil,
                includePiP: false,
                sourceAngle: recording.frontAngle,
                pipAngle: nil,
                sourceMirrored: true
            ) {
                frontWriter.appendVideo(pixelBuffer: rendered, presentationTime: presentationTime)
            }
    }

    private func handleAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard let recording = activeLoopRecording?.currentSegment else { return }

        switch recording.mode {
        case .pipSingleFile:
            recording.primaryWriter.appendAudio(sampleBuffer: sampleBuffer)
        case .dualSeparateFiles:
            recording.primaryWriter.appendAudio(sampleBuffer: sampleBuffer)
            recording.secondaryWriter?.appendAudio(sampleBuffer: sampleBuffer)
        }
    }
}

// recording writer

// each output file gets its own writer so the controller only has to think about routing and mode
