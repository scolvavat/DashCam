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

fileprivate struct DashFinishedSegmentRecord {
    var urls: [URL]
    let startedAt: Date
    let endedAt: Date
    let captureSnapshot: DashClipCaptureSnapshot
    var isSavedToLibrary: Bool
    var eventTags: [DashClipEventTag]
}

final class DashCamController: NSObject, ObservableObject {

    // Storage is intentionally split by sensitivity and lifecycle:
    // - rolling buffer: disposable capture data that should stay out of backups
    //   and live in Caches so the system can treat it as temporary data.
    // - saved clips/photos: app-private user-kept media that belongs in
    //   Application Support instead of Documents so it is not exposed as
    //   general-purpose user files by default.
    // - route history: sensitive location history that also stays private to the
    //   app and gets the strictest file protection we can reasonably use.
    //
    // The enum gives us one place to explain and enforce the policy so the
    // write sites later in the file do not have to duplicate the reasoning.
    fileprivate enum StoragePolicy {
        case retroBuffer
        case savedMedia
        case routeHistory

        // Rolling files may still be open while capture is active, so
        // `completeUnlessOpen` is the best fit there. Saved media and route
        // history are not expected to stay writable in the background, so we
        // upgrade them to `complete`.
        var fileProtection: FileProtectionType {
            switch self {
            case .retroBuffer:
                return .completeUnlessOpen
            case .savedMedia, .routeHistory:
                return .complete
            }
        }

        // The rolling buffer must never go to backup. Saved media is also
        // excluded by design here because dashcam footage tends to be large and
        // privacy-sensitive. Route history follows the same rule for privacy.
        var isExcludedFromBackup: Bool {
            true
        }
    }

    static let retroBufferFolderName = "RetroBuffer"
    private static let appStorageFolderName = "DashCam"
    private static let savedClipsFolderName = "Clips"
    private static let snapshotsFolderName = "Snapshots"
    private static let routeHistoryFileName = "route-history.json"

    // saved settings keys

    // keep the user facing app choices across launches so the app comes back
    // in the same recording configuration the user last picked.

    private enum SavedSettingKey {
        static let recordingMode = "dashcam.recordingMode"
        static let frontCameraEnabled = "dashcam.frontCameraEnabled"
        static let rearLens = "dashcam.rearLens"
        static let quality = "dashcam.quality"
        static let bitrateProfile = "dashcam.bitrateProfile"
        static let clipLength = "dashcam.clipLength"
        static let retroBufferLength = "dashcam.retroBufferLength"
        static let storageCap = "dashcam.storageCap"
        static let frameRate = "dashcam.frameRate"
        static let burnStamp = "dashcam.burnStamp"
        static let showCompass = "dashcam.showCompass"
        static let showMainExtraInfo = "dashcam.showMainExtraInfo"
        static let showMapBackground = "dashcam.showMapBackground"
        static let convoyEnabled = "dashcam.convoyEnabled"
        static let convoyServerURL = "dashcam.convoyServerURL"
        static let convoySessionCode = "dashcam.convoySessionCode"
        static let convoyDisplayName = "dashcam.convoyDisplayName"
        static let convoyUserID = "dashcam.convoyUserID"
        static let crashDetectionEnabled = "dashcam.crashDetectionEnabled"
        static let crashSensitivity = "dashcam.crashSensitivity"
        static let autoStartBySpeed = "dashcam.autoStartBySpeed"
        static let autoStartThresholdMPH = "dashcam.autoStartThresholdMPH"
    }

    private static func savedEnum<T: RawRepresentable>(forKey key: String, default defaultValue: T) -> T where T.RawValue == String {
        let defaults = UserDefaults.standard
        guard let rawValue = defaults.string(forKey: key),
              let value = T(rawValue: rawValue) else {
            return defaultValue
        }
        return value
    }

    private static func savedEnum<T: RawRepresentable>(forKey key: String, default defaultValue: T) -> T where T.RawValue == Int {
        let defaults = UserDefaults.standard
        guard let value = T(rawValue: defaults.integer(forKey: key)) else {
            return defaultValue
        }
        return value
    }

    private static func savedBool(forKey key: String, default defaultValue: Bool) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    private static func savedString(forKey key: String, default defaultValue: String) -> String {
        let defaults = UserDefaults.standard
        guard let value = defaults.string(forKey: key), !value.isEmpty else {
            return defaultValue
        }
        return value
    }

    private static func savedConvoyUserID() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: SavedSettingKey.convoyUserID), !existing.isEmpty {
            return existing
        }

        let generated = UUID().uuidString
        defaults.set(generated, forKey: SavedSettingKey.convoyUserID)
        return generated
    }

    private static func savedDouble(forKey key: String, default defaultValue: Double) -> Double {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return defaults.double(forKey: key)
    }

    private func handleSettingChange<Value: Equatable>(
        _ oldValue: Value,
        _ newValue: Value,
        afterChange: (() -> Void)? = nil
    ) {
        guard oldValue != newValue else { return }
        saveSettings()
        afterChange?()
    }

    @Published var showAlert: Bool = false
    @Published var alertMessage: String = ""
    @Published var isRunning: Bool = false
    @Published var isCaptureReady: Bool = false
    @Published var isAudioReady: Bool = false
    @Published var isLoopBufferActive: Bool = false
    @Published var isRecording: Bool = false
    @Published var detailText: String = "Waiting for camera permission..."
    @Published var savedClipText: String = "No clips saved yet."
    @Published var loopStatusText: String = "Loop 30s • cap 5 GB • local use unknown"
    @Published var recordingMode: RecordingMode = DashCamController.savedEnum(forKey: SavedSettingKey.recordingMode, default: .pipSingleFile) {
        didSet { handleSettingChange(oldValue, recordingMode) }
    }
    @Published var frontCameraEnabled: Bool = DashCamController.savedBool(forKey: SavedSettingKey.frontCameraEnabled, default: true) {
        didSet { handleSettingChange(oldValue, frontCameraEnabled) { self.applyFrontCameraStateChangeIfNeeded() } }
    }
    @Published var rearLens: RearLensOption = DashCamController.savedEnum(forKey: SavedSettingKey.rearLens, default: .wide) {
        didSet { handleSettingChange(oldValue, rearLens) { self.applyRearLensChangeIfNeeded() } }
    }
    @Published var quality: DashVideoQuality = DashCamController.savedEnum(forKey: SavedSettingKey.quality, default: .p720) {
        didSet { handleSettingChange(oldValue, quality) { self.refreshLoopStatusText(); self.applyCurrentCaptureFormatsIfPossible() } }
    }
    @Published var bitrateProfile: DashBitrateProfile = DashCamController.savedEnum(forKey: SavedSettingKey.bitrateProfile, default: .balanced) {
        didSet { handleSettingChange(oldValue, bitrateProfile) }
    }
    @Published var clipLength: DashClipLength = DashCamController.savedEnum(forKey: SavedSettingKey.clipLength, default: .s30) {
        didSet { handleSettingChange(oldValue, clipLength) { self.refreshLoopStatusText(); self.restartLoopTimerIfNeeded() } }
    }
    @Published var retroBufferLength: DashRetroBufferLength = DashCamController.savedEnum(forKey: SavedSettingKey.retroBufferLength, default: .s60) {
        didSet { handleSettingChange(oldValue, retroBufferLength) }
    }
    @Published var storageCap: DashStorageCap = DashCamController.savedEnum(forKey: SavedSettingKey.storageCap, default: .gb5) {
        didSet {
            handleSettingChange(oldValue, storageCap) {
                self.refreshLoopStatusText()
                self.captureQueue.async {
                    self.trimStorageIfNeeded(protecting: self.currentSegmentProtectedURLs())
                }
            }
        }
    }
    @Published var frameRate: DashFrameRate = DashCamController.savedEnum(forKey: SavedSettingKey.frameRate, default: .fps24) {
        didSet { handleSettingChange(oldValue, frameRate) { self.applyCurrentCaptureFormatsIfPossible() } }
    }
    @Published var burnStamp: Bool = DashCamController.savedBool(forKey: SavedSettingKey.burnStamp, default: true) {
        didSet { handleSettingChange(oldValue, burnStamp) }
    }
    @Published var showCompass: Bool = DashCamController.savedBool(forKey: SavedSettingKey.showCompass, default: false) {
        didSet { handleSettingChange(oldValue, showCompass) { self.updateLiveStampText() } }
    }
    @Published var showMainExtraInfo: Bool = DashCamController.savedBool(forKey: SavedSettingKey.showMainExtraInfo, default: false) {
        didSet { handleSettingChange(oldValue, showMainExtraInfo) }
    }
    @Published var showMapBackground: Bool = DashCamController.savedBool(forKey: SavedSettingKey.showMapBackground, default: true) {
        didSet { handleSettingChange(oldValue, showMapBackground) }
    }
    @Published var convoyEnabled: Bool = DashCamController.savedBool(forKey: SavedSettingKey.convoyEnabled, default: false) {
        didSet { handleSettingChange(oldValue, convoyEnabled) { self.updateConvoyConnectionState() } }
    }
    @Published var convoyServerURL: String = DashCamController.savedString(forKey: SavedSettingKey.convoyServerURL, default: "ws://127.0.0.1:8787") {
        didSet { handleSettingChange(oldValue, convoyServerURL) { self.updateConvoyConnectionState() } }
    }
    @Published var convoySessionCode: String = DashCamController.savedString(forKey: SavedSettingKey.convoySessionCode, default: "test-drive") {
        didSet { handleSettingChange(oldValue, convoySessionCode) { self.updateConvoyConnectionState() } }
    }
    @Published var convoyDisplayName: String = DashCamController.savedString(forKey: SavedSettingKey.convoyDisplayName, default: UIDevice.current.name) {
        didSet { handleSettingChange(oldValue, convoyDisplayName) { self.updateConvoyConnectionState() } }
    }
    @Published var convoyStatusText: String = "Convoy off"
    @Published var convoyFriends: [DashFriendPresence] = []
    @Published var crashDetectionEnabled: Bool = DashCamController.savedBool(forKey: SavedSettingKey.crashDetectionEnabled, default: false) {
        didSet { handleSettingChange(oldValue, crashDetectionEnabled) { self.updateCrashDetectionState() } }
    }
    @Published var crashSensitivity: DashCrashSensitivity = DashCamController.savedEnum(forKey: SavedSettingKey.crashSensitivity, default: .balanced) {
        didSet { handleSettingChange(oldValue, crashSensitivity) { self.updateCrashDetectionState() } }
    }
    @Published var crashStatusText: String = "Crash detection off"
    @Published var liveStampText: String = "GPS waiting..."
    @Published var autoStartBySpeed: Bool = DashCamController.savedBool(forKey: SavedSettingKey.autoStartBySpeed, default: false) {
        didSet { handleSettingChange(oldValue, autoStartBySpeed) { self.handleAutoStartToggleChange() } }
    }
    @Published var autoStartThresholdMPH: Double = DashCamController.savedDouble(forKey: SavedSettingKey.autoStartThresholdMPH, default: 5) {
        didSet { handleSettingChange(oldValue, autoStartThresholdMPH) { self.resetAutoSpeedCounters(); self.updateSpeedStatusText(with: self.locationManager.speedMetersPerSecond) } }
    }
    @Published var speedStatusText: String = "Speed 0.0 mph • auto start off"

    let session: AVCaptureSession
    let locationManager = DashLocationManager()
    let convoyPresenceService = DashConvoyPresenceService()
    let crashDetector = DashCrashDetector()
    let convoyUserID = DashCamController.savedConvoyUserID()

    let sessionQueue = DispatchQueue(label: "dashcam.session.queue")
    let captureQueue = DispatchQueue(label: "dashcam.capture.queue")
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
    var hasStartedAncillaryServices: Bool = false
    var ancillaryServicesStartWorkItem: DispatchWorkItem?
    var activeRouteTitle: String?
    var activeRouteSubtitle: String?
    fileprivate var recentFinishedSegments: [DashFinishedSegmentRecord] = []
    var shouldProtectNewSegments: Bool = false
    var currentRecordingSessionTags: [DashClipEventTag] = []

    var rearVideoInput: AVCaptureDeviceInput?
    var frontVideoInput: AVCaptureDeviceInput?
    var audioInput: AVCaptureDeviceInput?

    let rearVideoOutput = AVCaptureVideoDataOutput()
    let frontVideoOutput = AVCaptureVideoDataOutput()
    let audioOutput = AVCaptureAudioDataOutput()

    var latestFrontPixelBuffer: CVPixelBuffer?
    var lastFrontPiPBufferPush: CFTimeInterval = 0
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

        locationManager.$headingDegrees
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateLiveStampText()
            }
            .store(in: &cancellables)

        locationManager.$latestLocation
            .receive(on: RunLoop.main)
            .sink { [weak self] location in
                self?.publishConvoyLocationIfNeeded(location)
            }
            .store(in: &cancellables)

        convoyPresenceService.onFriendsChanged = { [weak self] friends in
            self?.convoyFriends = friends
        }

        convoyPresenceService.onStatusChanged = { [weak self] status in
            self?.convoyStatusText = status
        }

        crashDetector.onStatusChanged = { [weak self] status in
            self?.crashStatusText = status
        }

        crashDetector.onImpactDetected = { [weak self] magnitude in
            self?.handlePotentialCrashImpact(magnitudeG: magnitude)
        }

        // Run storage migration once during controller setup so older builds that
        // wrote into Documents do not strand the user's existing saved clips.
        // The migration is silent and best-effort because losing access to the
        // camera over a failed housekeeping step would be a worse outcome than
        // continuing with the old files still on disk.
        Self.migrateLegacyClipStorageIfNeeded()

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

    // MARK: - Storage policy helpers

    // Keep all app-private, user-kept media under Application Support so the
    // files are managed by the app instead of presented as loose Documents.
    private static func applicationSupportRootURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL.appendingPathComponent(appStorageFolderName, isDirectory: true)
    }

    // The rolling buffer is intentionally disposable, so it lives under Caches.
    private static func cachesRootURL() -> URL {
        let baseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL.appendingPathComponent(appStorageFolderName, isDirectory: true)
    }

    // Older builds stored everything under Documents/DashCamClips. We keep that
    // path around only as a migration source so we can move legacy media into
    // the new private storage model.
    private static func legacyDocumentsClipsFolderURL() -> URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return documentsURL.appendingPathComponent("DashCamClips", isDirectory: true)
    }

    // Directories get the same storage policy as the files they contain so that
    // newly created children inherit a sensible default even before we harden
    // the individual file once writing finishes.
    @discardableResult
    private static func ensureDirectory(at directoryURL: URL, policy: StoragePolicy) throws -> URL {
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        try applyStoragePolicy(to: directoryURL, policy: policy)
        return directoryURL
    }

    // This is the one place that actually mutates file-system protection and
    // backup attributes. Every write path funnels back here so the storage
    // policy stays coherent across video, photos, metadata, and route history.
    private static func applyStoragePolicy(to url: URL, policy: StoragePolicy) throws {
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = policy.isExcludedFromBackup

        var mutableURL = url
        try mutableURL.setResourceValues(resourceValues)
        try FileManager.default.setAttributes([.protectionKey: policy.fileProtection], ofItemAtPath: url.path)
    }

    // Saved clip metadata sits beside the media file and contains the most
    // privacy-sensitive details such as timestamps, GPS, and route context. We
    // therefore treat the sidecar as part of the same protected artifact.
    private static func applyStoragePolicyIfPresent(to url: URL, policy: StoragePolicy) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try applyStoragePolicy(to: url, policy: policy)
    }

    static func applySavedMediaProtection(to mediaURL: URL) throws {
        try applyStoragePolicyIfPresent(to: mediaURL, policy: .savedMedia)
        try applyStoragePolicyIfPresent(to: DashClipMetadataStore.metadataURL(for: mediaURL), policy: .savedMedia)
    }

    static func applyTemporaryBufferProtection(to mediaURL: URL) throws {
        try applyStoragePolicyIfPresent(to: mediaURL, policy: .retroBuffer)
        try applyStoragePolicyIfPresent(to: DashClipMetadataStore.metadataURL(for: mediaURL), policy: .retroBuffer)
    }

    static func applyRouteHistoryProtection(to historyURL: URL) throws {
        try applyStoragePolicyIfPresent(to: historyURL, policy: .routeHistory)
    }

    static func clipsFolderURL() throws -> URL {
        try ensureDirectory(
            at: applicationSupportRootURL().appendingPathComponent(savedClipsFolderName, isDirectory: true),
            policy: .savedMedia
        )
    }

    static func retroBufferFolderURL() throws -> URL {
        try ensureDirectory(
            at: cachesRootURL().appendingPathComponent(retroBufferFolderName, isDirectory: true),
            policy: .retroBuffer
        )
    }

    static func routeHistoryFileURL() throws -> URL {
        let rootURL = try ensureDirectory(at: applicationSupportRootURL(), policy: .routeHistory)
        return rootURL.appendingPathComponent(routeHistoryFileName)
    }

    // Legacy migration is intentionally file-based instead of directory-renaming
    // because the new layout splits temporary and saved data across different
    // roots. That means we only migrate user-kept media and snapshots and leave
    // the old rolling buffer behind as disposable junk.
    private static func migrateLegacyClipStorageIfNeeded() {
        let legacyRootURL = legacyDocumentsClipsFolderURL()
        guard FileManager.default.fileExists(atPath: legacyRootURL.path) else { return }

        do {
            let destinationRootURL = try clipsFolderURL()
            let legacyEntries = try FileManager.default.contentsOfDirectory(
                at: legacyRootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for legacyEntryURL in legacyEntries {
                if legacyEntryURL.lastPathComponent == retroBufferFolderName {
                    // The old Documents-based rolling buffer is disposable by
                    // definition, so we explicitly delete it instead of
                    // migrating it into the new saved-media area.
                    try? FileManager.default.removeItem(at: legacyEntryURL)
                    continue
                }

                let resourceValues = try? legacyEntryURL.resourceValues(forKeys: [.isDirectoryKey])
                let destinationURL = destinationRootURL.appendingPathComponent(
                    legacyEntryURL.lastPathComponent,
                    isDirectory: resourceValues?.isDirectory == true
                )

                try mergeLegacyItem(at: legacyEntryURL, into: destinationURL)
            }

            // If everything was moved out cleanly, remove the now-obsolete
            // Documents folder so future launches do not keep rescanning it.
            let remainingEntries = try FileManager.default.contentsOfDirectory(
                at: legacyRootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            if remainingEntries.isEmpty {
                try? FileManager.default.removeItem(at: legacyRootURL)
            }
        } catch {
            // Migration is best-effort. We intentionally swallow errors here so
            // storage housekeeping cannot block camera startup.
        }
    }

    // Merge recursively so a legacy Snapshots folder can be folded into the new
    // Application Support tree without overwriting newer files that may already
    // exist there.
    private static func mergeLegacyItem(at sourceURL: URL, into destinationURL: URL) throws {
        let resourceValues = try? sourceURL.resourceValues(forKeys: [.isDirectoryKey])

        if resourceValues?.isDirectory == true {
            try ensureDirectory(at: destinationURL, policy: .savedMedia)
            let children = try FileManager.default.contentsOfDirectory(
                at: sourceURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for childURL in children {
                let childDestinationURL = destinationURL.appendingPathComponent(childURL.lastPathComponent)
                try mergeLegacyItem(at: childURL, into: childDestinationURL)
            }

            try? FileManager.default.removeItem(at: sourceURL)
            return
        }

        let finalDestinationURL = uniqueDestinationURL(for: destinationURL.lastPathComponent, in: destinationURL.deletingLastPathComponent())
        try FileManager.default.moveItem(at: sourceURL, to: finalDestinationURL)
        try applyStoragePolicy(to: finalDestinationURL, policy: .savedMedia)
    }

    // Filename collisions are handled conservatively by suffixing the incoming
    // legacy file. That keeps migration lossless and avoids silently clobbering
    // newer clips already written by the hardened layout.
    private static func uniqueDestinationURL(for fileName: String, in folderURL: URL) -> URL {
        let baseURL = folderURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: baseURL.path) else { return baseURL }

        let ext = baseURL.pathExtension
        let stem = baseURL.deletingPathExtension().lastPathComponent
        var counter = 1

        while true {
            let candidateFileName = ext.isEmpty ? "\(stem)_\(counter)" : "\(stem)_\(counter).\(ext)"
            let candidateURL = folderURL.appendingPathComponent(candidateFileName)
            if !FileManager.default.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
            counter += 1
        }
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
        try Self.ensureDirectory(
            at: Self.clipsFolderURL().appendingPathComponent(Self.snapshotsFolderName, isDirectory: true),
            policy: .savedMedia
        )
    }

    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(recordingMode.rawValue, forKey: SavedSettingKey.recordingMode)
        defaults.set(frontCameraEnabled, forKey: SavedSettingKey.frontCameraEnabled)
        defaults.set(rearLens.rawValue, forKey: SavedSettingKey.rearLens)
        defaults.set(quality.rawValue, forKey: SavedSettingKey.quality)
        defaults.set(bitrateProfile.rawValue, forKey: SavedSettingKey.bitrateProfile)
        defaults.set(clipLength.rawValue, forKey: SavedSettingKey.clipLength)
        defaults.set(retroBufferLength.rawValue, forKey: SavedSettingKey.retroBufferLength)
        defaults.set(storageCap.rawValue, forKey: SavedSettingKey.storageCap)
        defaults.set(frameRate.rawValue, forKey: SavedSettingKey.frameRate)
        defaults.set(burnStamp, forKey: SavedSettingKey.burnStamp)
        defaults.set(showCompass, forKey: SavedSettingKey.showCompass)
        defaults.set(showMainExtraInfo, forKey: SavedSettingKey.showMainExtraInfo)
        defaults.set(showMapBackground, forKey: SavedSettingKey.showMapBackground)
        defaults.set(convoyEnabled, forKey: SavedSettingKey.convoyEnabled)
        defaults.set(convoyServerURL, forKey: SavedSettingKey.convoyServerURL)
        defaults.set(convoySessionCode, forKey: SavedSettingKey.convoySessionCode)
        defaults.set(convoyDisplayName, forKey: SavedSettingKey.convoyDisplayName)
        defaults.set(convoyUserID, forKey: SavedSettingKey.convoyUserID)
        defaults.set(crashDetectionEnabled, forKey: SavedSettingKey.crashDetectionEnabled)
        defaults.set(crashSensitivity.rawValue, forKey: SavedSettingKey.crashSensitivity)
        defaults.set(autoStartBySpeed, forKey: SavedSettingKey.autoStartBySpeed)
        defaults.set(autoStartThresholdMPH, forKey: SavedSettingKey.autoStartThresholdMPH)
        defaults.synchronize()
    }

    var multiCamSupported: Bool {
        multiSessionSupported
    }

    var isFrontCameraCaptureActive: Bool {
        multiCamSupported && frontCameraEnabled
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

    var isUsingDualCameraRecording: Bool {
        recordingMode == .dualSeparateFiles && isFrontCameraCaptureActive
    }

    func activeRecordingDescription() -> String {
        if quality == .p4K {
            if isFrontCameraCaptureActive {
                return recordingMode == .pipSingleFile
                    ? "Loop recording 4K rear clips with front PiP at \(frameRate.rawValue) fps..."
                    : "Loop recording 4K rear and front clips at \(frameRate.rawValue) fps..."
            }

            return "Loop recording 4K rear-only clips at \(frameRate.rawValue) fps..."
        }

        if isFrontCameraCaptureActive {
            return recordingMode == .pipSingleFile
                ? "Loop recording PiP clips..."
                : "Loop recording rear and front clips..."
        }

        return "Loop recording rear-only clips..."
    }

    func updateActiveRouteContext(title: String?, subtitle: String?) {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedSubtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        activeRouteTitle = trimmedTitle.isEmpty ? nil : trimmedTitle
        activeRouteSubtitle = activeRouteTitle == nil ? nil : trimmedSubtitle
    }

    func currentCaptureSnapshot(recordedAt: Date = Date()) -> DashClipCaptureSnapshot {
        let routeContext: DashClipRouteContext?
        if let activeRouteTitle {
            routeContext = DashClipRouteContext(
                title: activeRouteTitle,
                subtitle: activeRouteSubtitle ?? ""
            )
        } else {
            routeContext = nil
        }

        return DashClipCaptureSnapshot(
            recordedAt: recordedAt,
            coordinate: locationManager.latestLocation.map { DashClipCoordinate($0.coordinate) },
            speedMetersPerSecond: locationManager.speedMetersPerSecond,
            headingDegrees: locationManager.headingDegrees,
            route: routeContext
        )
    }

    func defaultEventTags(for snapshot: DashClipCaptureSnapshot) -> [DashClipEventTag] {
        snapshot.route == nil ? [] : [.routeLinked]
    }

    func persistClipMetadata(
        for mediaURL: URL,
        source: DashClipSource,
        startedAt: Date,
        endedAt: Date,
        durationSeconds: Double?,
        snapshot: DashClipCaptureSnapshot,
        protected isProtected: Bool,
        eventTags: [DashClipEventTag]
    ) {
        var metadata = DashClipMetadata(
            mediaFileName: mediaURL.lastPathComponent,
            source: source,
            startedAt: startedAt,
            endedAt: endedAt,
            recordingMode: source == .recordingSegment ? recordingMode.rawValue : nil,
            quality: source == .recordingSegment ? quality.rawValue : nil,
            rearLens: rearLens.rawValue,
            durationSeconds: durationSeconds,
            captureSnapshot: snapshot,
            isProtected: isProtected,
            eventTags: []
        )
        metadata.add(tags: eventTags, protected: isProtected)
        try? DashClipMetadataStore.save(metadata, for: mediaURL)
        try? Self.applySavedMediaProtection(to: mediaURL)
    }

    fileprivate func addProtection(to records: [DashFinishedSegmentRecord], tags: [DashClipEventTag]) {
        for record in records {
            let mergedTags = mergedEventTags(defaultEventTags(for: record.captureSnapshot), tags)
            let durationSeconds = max(record.endedAt.timeIntervalSince(record.startedAt), 0)

            for mediaURL in record.urls {
                if DashClipMetadataStore.load(for: mediaURL) != nil {
                    DashClipMetadataStore.update(for: mediaURL) { metadata in
                        metadata.add(tags: mergedTags, protected: true)
                    }
                    continue
                }

                persistClipMetadata(
                    for: mediaURL,
                    source: .recordingSegment,
                    startedAt: record.startedAt,
                    endedAt: record.endedAt,
                    durationSeconds: durationSeconds,
                    snapshot: record.captureSnapshot,
                    protected: true,
                    eventTags: mergedTags
                )
            }
        }
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
        }
        if isLoopBufferActive {
            return "BUFFER READY"
        }
        return isRunning ? "CAMERA READY" : "CAMERA OFF"
    }

    var canRecord: Bool {
        isCaptureReady && isAudioReady
    }

    var retroBufferDescription: String {
        "Camera ready. A rolling \(retroBufferLength.label.lowercased()) is armed in the background."
    }

    func start() {
        if rearLens == .ultraWide && !isUltraWideAvailable {
            rearLens = .wide
        }

        isSceneActive = true
        startLiveClock()
        startOrientationTracking()
        requestPermissionsThenStart()
    }

    func stop() {
        isSceneActive = false
        ancillaryServicesStartWorkItem?.cancel()
        ancillaryServicesStartWorkItem = nil
        hasStartedAncillaryServices = false
        convoyPresenceService.disconnect()
        crashDetector.stop()
        locationManager.stop()
        stopLoopCaptureSynchronouslyIfNeeded(
            reason: "Stopping camera...",
            shouldKeepBuffering: false,
            shouldAnnounce: false
        )
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
            stopLoopCaptureIfNeeded(
                reason: "Saved the recording. Rolling buffer is still live.",
                shouldKeepBuffering: true,
                shouldAnnounce: false
            )
        } else {
            guard canRecord else {
                pendingManualRecordingRequest = true
                detailText = "Camera is still starting. Recording will begin as soon as video and audio are ready."
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

    func saveCurrentMoment() {
        markCurrentMoment(tags: [.manualSave], detailMessage: "Saved this moment. The buffered clips around it will stay protected.")
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

    func markCurrentMoment(tags: [DashClipEventTag], detailMessage: String) {
        captureQueue.async {
            guard let currentSegment = self.activeLoopRecording?.currentSegment else {
                DispatchQueue.main.async {
                    self.detailText = "Rolling buffer is not ready yet."
                }
                return
            }

            self.protectBufferedHistory(tags: tags, referenceDate: Date())
            currentSegment.addEvent(tags: tags, protected: true)

            DispatchQueue.main.async {
                self.detailText = detailMessage
            }
        }
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isSceneActive = true
            updateCurrentAngles()
            startAncillaryServicesIfNeeded()
            evaluateAutoStartStop(with: locationManager.speedMetersPerSecond)
        default:
            saveSettings()
            isSceneActive = false
            ancillaryServicesStartWorkItem?.cancel()
            ancillaryServicesStartWorkItem = nil
            hasStartedAncillaryServices = false
            pendingManualRecordingRequest = false
            resetCaptureReadiness(includeAudio: audioInput != nil)
            convoyPresenceService.disconnect()
            crashDetector.stop()
            locationManager.stop()
            if activeLoopRecording != nil {
                stopLoopCaptureIfNeeded(
                    reason: "Stopped because the app left the foreground.",
                    shouldKeepBuffering: false,
                    shouldAnnounce: false
                )
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
            stopLoopCaptureIfNeeded(
                reason: "Auto start by speed turned off. Rolling buffer is still live.",
                shouldKeepBuffering: true,
                shouldAnnounce: false
            )
        }
    }

    func evaluateAutoStartStop(with speedMetersPerSecond: Double?) {
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
                stopLoopCaptureIfNeeded(
                    reason: "Auto stopped below speed threshold. Rolling buffer is still live.",
                    shouldKeepBuffering: true,
                    shouldAnnounce: false
                )
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
            self.ensureLoopBufferRunningIfPossible()
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
            self.ensureLoopBufferRunningIfPossible()
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
        stopLoopCaptureSynchronouslyIfNeeded(
            reason: detailText,
            shouldKeepBuffering: false,
            shouldAnnounce: false
        )

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

    func applyFrontCameraStateChangeIfNeeded() {
        latestFrontPixelBuffer = nil
        guard didConfigureSession else { return }
        guard multiCamSupported else { return }
        guard !isRecording else {
            detailText = "Stop recording before changing the front camera setting."
            return
        }

        let includeAudio = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        detailText = frontCameraEnabled ? "Enabling front camera..." : "Disabling front camera..."
        pendingManualRecordingRequest = false
        resetCaptureReadiness(includeAudio: includeAudio)
        hasPreparedAudioSession = false
        stopLoopCaptureSynchronouslyIfNeeded(
            reason: detailText,
            shouldKeepBuffering: false,
            shouldAnnounce: false
        )

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
    }

    // recording

    // recording works as a rolling series of short segments

    // every time one segment closes, storage cleanup runs and deletes the oldest finished files until we are back under the cap

    // The dashcam now keeps a quiet rolling loop alive as soon as capture is warm.
    // That loop is the retro-save buffer. Manual record no longer means "start
    // encoding from zero"; instead it means "protect the buffered footage and keep
    // protecting new segments until the user stops."

    private func ensureLoopBufferRunningIfPossible() {
        captureQueue.async {
            guard self.canRecord else { return }
            guard self.activeLoopRecording == nil else { return }

            do {
                self.clearRetroBufferFolderContents()
                let bufferFolderURL = try Self.retroBufferFolderURL()
                let loop = ActiveLoopRecording(
                    folderURL: bufferFolderURL,
                    sessionID: self.recordingTimestampString(),
                    rearAngle: self.rearCaptureAngle,
                    frontAngle: self.frontCaptureAngle
                )

                try self.startNextSegment(in: loop)
                self.installSegmentTimer(for: loop)
                self.activeLoopRecording = loop
                self.recentFinishedSegments = []

                DispatchQueue.main.async {
                    self.isLoopBufferActive = true
                    if !self.isRecording {
                        self.detailText = self.retroBufferDescription
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

    // Enter saved-recording mode by promoting the rolling buffer into protected
    // media. The important extra step is forcing an immediate segment boundary:
    // without that, the current buffered segment would stay open until the normal
    // 15s/30s/60s/120s rollover and the Clips sheet would look empty even though
    // the buffer had technically been marked for protection.

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

            if self.activeLoopRecording == nil {
                do {
                    self.clearRetroBufferFolderContents()
                    let bufferFolderURL = try Self.retroBufferFolderURL()
                    let loop = ActiveLoopRecording(
                        folderURL: bufferFolderURL,
                        sessionID: self.recordingTimestampString(),
                        rearAngle: self.rearCaptureAngle,
                        frontAngle: self.frontCaptureAngle
                    )

                    try self.startNextSegment(in: loop)
                    self.installSegmentTimer(for: loop)
                    self.activeLoopRecording = loop
                    self.recentFinishedSegments = []
                } catch {
                    DispatchQueue.main.async {
                        self.alertMessage = error.localizedDescription
                        self.detailText = error.localizedDescription
                        self.showAlert = true
                    }
                    return
                }
            }

            guard !self.isRecording else { return }

            let sessionTags: [DashClipEventTag] = triggeredByAutoSpeed ? [] : [.manualSave]
            self.currentRecordingSessionTags = sessionTags
            self.shouldProtectNewSegments = true
            self.isAutoSpeedRecording = triggeredByAutoSpeed

            let saveStartedAt = Date()
            self.protectBufferedHistory(tags: sessionTags, referenceDate: saveStartedAt)
            self.activeLoopRecording?.currentSegment?.addEvent(tags: sessionTags, protected: true)

            if let loop = self.activeLoopRecording {
                self.rotateToNextSegment(for: loop, shouldAnnounce: false)
            }

            DispatchQueue.main.async {
                self.isLoopBufferActive = true
                self.isRecording = true
                self.detailText = triggeredByAutoSpeed
                    ? "Speed threshold reached. Saved the last \(self.retroBufferLength.shortLabel) and kept recording."
                    : "Saved the last \(self.retroBufferLength.shortLabel) and kept recording."
                self.refreshLoopStatusText()
            }
        }
    }

    private func stopLoopCaptureIfNeeded(reason: String, shouldKeepBuffering: Bool, shouldAnnounce: Bool) {
        captureQueue.async {
            self.stopLoopCaptureOnCaptureQueue(
                reason: reason,
                shouldKeepBuffering: shouldKeepBuffering,
                shouldAnnounce: shouldAnnounce
            )
        }
    }

    private func stopLoopCaptureSynchronouslyIfNeeded(reason: String, shouldKeepBuffering: Bool, shouldAnnounce: Bool) {
        captureQueue.sync {
            self.stopLoopCaptureOnCaptureQueue(
                reason: reason,
                shouldKeepBuffering: shouldKeepBuffering,
                shouldAnnounce: shouldAnnounce
            )
        }
    }

    // Stopping now has two paths:
    // 1. keep buffering: close the protected segment and immediately start a new
    //    disposable segment so retro-save stays armed.
    // 2. stop completely: tear the loop down because the app is stopping or the
    //    capture graph is being rebuilt.

    private func stopLoopCaptureOnCaptureQueue(reason: String, shouldKeepBuffering: Bool, shouldAnnounce: Bool) {
        guard let loop = activeLoopRecording else { return }

        if shouldKeepBuffering {
            guard isRecording else { return }

            shouldProtectNewSegments = false
            currentRecordingSessionTags = []
            isAutoSpeedRecording = false
            resetAutoSpeedCounters()

            DispatchQueue.main.async {
                self.isRecording = false
                self.isLoopBufferActive = true
                self.detailText = reason
            }

            rotateToNextSegment(for: loop, shouldAnnounce: shouldAnnounce)
            return
        }

        activeLoopRecording = nil
        shouldProtectNewSegments = false
        currentRecordingSessionTags = []
        isAutoSpeedRecording = false
        resetAutoSpeedCounters()
        loop.segmentTimer?.cancel()
        loop.segmentTimer = nil

        let finalSegment = loop.currentSegment
        loop.currentSegment = nil

        DispatchQueue.main.async {
            self.detailText = reason
            self.isRecording = false
            self.isLoopBufferActive = false
        }

        if let finalSegment {
            finishSegment(finalSegment, isFinalStop: true, shouldAnnounce: shouldAnnounce)
        }
    }

    private func installSegmentTimer(for loop: ActiveLoopRecording) {
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + clipLength.seconds, repeating: clipLength.seconds)
        timer.setEventHandler { [weak self, weak loop] in
            guard let self, let loop, let active = self.activeLoopRecording, active === loop else { return }
            self.rotateToNextSegment(for: loop, shouldAnnounce: self.isRecording)
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

    private func rotateToNextSegment(for loop: ActiveLoopRecording, shouldAnnounce: Bool) {
        let previousSegment = loop.currentSegment

        do {
            try startNextSegment(in: loop)

            if let previousSegment {
                finishSegment(previousSegment, isFinalStop: false, shouldAnnounce: shouldAnnounce)
            }

            if shouldAnnounce {
                DispatchQueue.main.async {
                    self.detailText = "Loop recording segment \(loop.segmentIndex)..."
                }
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

    private func finishSegment(_ recording: ActiveRecording, isFinalStop: Bool, shouldAnnounce: Bool) {
        let writers = recording.writers
        let sourceURLs = writers.map(\.url)
        let finishedAt = Date()
        recording.finishedAt = finishedAt
        let group = DispatchGroup()

        for writer in writers {
            group.enter()
            writer.finish {
                group.leave()
            }
        }

        group.notify(queue: captureQueue) {
            let eventTags = recording.eventTags
            let durationSeconds = max(finishedAt.timeIntervalSince(recording.startedAt), 0)
            let finalizedURLs: [URL]

            if recording.isProtected {
                do {
                    finalizedURLs = try self.promoteMediaURLsToSavedLibrary(sourceURLs)
                } catch {
                    DispatchQueue.main.async {
                        self.alertMessage = error.localizedDescription
                        self.detailText = "Could not save the protected clip from the retro buffer."
                        self.showAlert = true
                    }
                    return
                }

                for url in finalizedURLs {
                    self.persistClipMetadata(
                        for: url,
                        source: .recordingSegment,
                        startedAt: recording.startedAt,
                        endedAt: finishedAt,
                        durationSeconds: durationSeconds,
                        snapshot: recording.captureSnapshot,
                        protected: true,
                        eventTags: eventTags
                    )
                }
            } else {
                finalizedURLs = sourceURLs

                // The parent folder already has the temporary policy, but once a
                // segment has finished writing we explicitly harden the file too
                // so the protection does not depend on directory inheritance.
                for url in finalizedURLs {
                    try? Self.applyTemporaryBufferProtection(to: url)
                }
            }

            self.recordFinishedSegment(
                urls: finalizedURLs,
                startedAt: recording.startedAt,
                endedAt: finishedAt,
                captureSnapshot: recording.captureSnapshot,
                isSavedToLibrary: recording.isProtected,
                eventTags: eventTags
            )
            self.trimStorageIfNeeded(protecting: self.currentSegmentProtectedURLs())

            DispatchQueue.main.async {
                self.refreshLoopStatusText()
                guard shouldAnnounce else { return }
                self.savedClipText = finalizedURLs.map(\.lastPathComponent).joined(separator: " • ")
                self.detailText = isFinalStop ? "Final loop clip saved locally." : "Loop clip rotated and saved locally."
            }
        }
    }

    private func makeRecordingBundle(folderURL: URL, sessionID: String, segmentIndex: Int, rearAngle: CGFloat, frontAngle: CGFloat) throws -> ActiveRecording {
        let rearCanvas = quality.size
        let frontQuality = frontTargetQuality
        let frontCanvas = frontQuality.size
        let includeFrontCamera = isFrontCameraCaptureActive
        let audioEnabled = audioInput != nil
        let segmentString = String(format: "%03d", segmentIndex)
        let startedAt = Date()
        let captureSnapshot = currentCaptureSnapshot(recordedAt: startedAt)
        let initialTags = mergedEventTags(defaultEventTags(for: captureSnapshot), currentRecordingSessionTags)
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
            // AVAssetWriter may create the destination file lazily depending on
            // the platform state, so this call is best-effort. The directory is
            // already hardened and we harden the finished file again after
            // rotation, but applying the policy here covers the common case
            // where the file already exists immediately after writer creation.
            try? Self.applyTemporaryBufferProtection(to: comboURL)
            return ActiveRecording(
                mode: .pipSingleFile,
                primaryWriter: comboWriter,
                secondaryWriter: nil,
                rearAngle: rearAngle,
                frontAngle: frontAngle,
                includeFrontInPiP: includeFrontCamera,
                startedAt: startedAt,
                captureSnapshot: captureSnapshot,
                isProtected: shouldProtectNewSegments,
                eventTags: initialTags
            )

        case .dualSeparateFiles:
            let rearURL = folderURL.appendingPathComponent("DashCam_\(sessionID)_segment_\(segmentString)_rear.mov")
            let rearWriter = try RecordingWriter(
                url: rearURL,
                canvasSize: rearCanvas,
                quality: quality,
                includeAudio: audioEnabled,
                bitRateOverride: adjustedBitrate(for: quality)
            )
            try? Self.applyTemporaryBufferProtection(to: rearURL)
            let frontWriter: RecordingWriter?
            if includeFrontCamera {
                let frontURL = folderURL.appendingPathComponent("DashCam_\(sessionID)_segment_\(segmentString)_front.mov")
                frontWriter = try RecordingWriter(
                    url: frontURL,
                    canvasSize: frontCanvas,
                    quality: frontQuality,
                    includeAudio: audioEnabled,
                    bitRateOverride: adjustedBitrate(for: frontQuality)
                )
                try? Self.applyTemporaryBufferProtection(to: frontURL)
            } else {
                frontWriter = nil
            }

            if !burnStamp {
                rearWriter.setVideoTransform(transformForRotationAngle(rearAngle, canvasSize: rearCanvas))
                if let frontWriter {
                    frontWriter.setVideoTransform(transformForRotationAngle(frontAngle, canvasSize: frontCanvas))
                }
            }

            return ActiveRecording(
                mode: .dualSeparateFiles,
                primaryWriter: rearWriter,
                secondaryWriter: frontWriter,
                rearAngle: rearAngle,
                frontAngle: frontAngle,
                includeFrontInPiP: includeFrontCamera,
                startedAt: startedAt,
                captureSnapshot: captureSnapshot,
                isProtected: shouldProtectNewSegments,
                eventTags: initialTags
            )
        }
    }

    private func mergedEventTags(_ first: [DashClipEventTag], _ second: [DashClipEventTag]) -> [DashClipEventTag] {
        var merged = first
        for tag in second where !merged.contains(tag) {
            merged.append(tag)
        }
        return merged
    }

    private func recordFinishedSegment(
        urls: [URL],
        startedAt: Date,
        endedAt: Date,
        captureSnapshot: DashClipCaptureSnapshot,
        isSavedToLibrary: Bool,
        eventTags: [DashClipEventTag]
    ) {
        recentFinishedSegments.append(
            DashFinishedSegmentRecord(
                urls: urls,
                startedAt: startedAt,
                endedAt: endedAt,
                captureSnapshot: captureSnapshot,
                isSavedToLibrary: isSavedToLibrary,
                eventTags: eventTags
            )
        )

        pruneExpiredRetroBufferSegments(referenceDate: endedAt)
    }

    // When retro-save fires, we keep every finished segment whose tail overlaps
    // the requested look-back window. This is intentionally time-based instead of
    // "last N segments" so it still behaves correctly when the user switches clip
    // lengths between 15s, 30s, 60s, and 120s.

    private func protectBufferedHistory(tags: [DashClipEventTag], referenceDate: Date) {
        let cutoff = referenceDate.addingTimeInterval(-retroBufferLength.seconds)
        for index in recentFinishedSegments.indices where recentFinishedSegments[index].endedAt >= cutoff {
            promoteRecordToSavedLibraryIfNeeded(at: index, tags: tags)
        }
    }

    private func clearRetroBufferFolderContents() {
        guard let folderURL = try? Self.retroBufferFolderURL() else { return }
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil) else { return }

        for url in urls {
            try? FileManager.default.removeItem(at: url)
            DashClipMetadataStore.remove(for: url)
        }
    }

    private func promoteMediaURLsToSavedLibrary(_ urls: [URL]) throws -> [URL] {
        let destinationFolderURL = try Self.clipsFolderURL()
        return try urls.map { sourceURL in
            if sourceURL.deletingLastPathComponent() == destinationFolderURL {
                try? Self.applySavedMediaProtection(to: sourceURL)
                return sourceURL
            }

            let destinationURL = uniqueMediaDestinationURL(
                for: sourceURL.lastPathComponent,
                in: destinationFolderURL
            )
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)

            let sourceMetadataURL = DashClipMetadataStore.metadataURL(for: sourceURL)
            if FileManager.default.fileExists(atPath: sourceMetadataURL.path) {
                let destinationMetadataURL = DashClipMetadataStore.metadataURL(for: destinationURL)
                try? FileManager.default.moveItem(at: sourceMetadataURL, to: destinationMetadataURL)
            }

            // Promotion is the moment a disposable buffer segment becomes
            // user-kept evidence. Re-apply the saved-media policy after the move
            // so the file and its sidecar no longer inherit the temporary buffer
            // policy from Caches.
            try? Self.applySavedMediaProtection(to: destinationURL)
            return destinationURL
        }
    }

    private func uniqueMediaDestinationURL(for fileName: String, in folderURL: URL) -> URL {
        let baseURL = folderURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: baseURL.path) else { return baseURL }

        let ext = baseURL.pathExtension
        let stem = baseURL.deletingPathExtension().lastPathComponent
        var counter = 1

        while true {
            let candidateFileName = ext.isEmpty ? "\(stem)_\(counter)" : "\(stem)_\(counter).\(ext)"
            let candidateURL = folderURL.appendingPathComponent(candidateFileName)
            if !FileManager.default.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
            counter += 1
        }
    }

    private func promoteRecordToSavedLibraryIfNeeded(at index: Int, tags: [DashClipEventTag]) {
        guard recentFinishedSegments.indices.contains(index) else { return }

        var record = recentFinishedSegments[index]
        let mergedTags = mergedEventTags(
            mergedEventTags(defaultEventTags(for: record.captureSnapshot), record.eventTags),
            tags
        )
        let durationSeconds = max(record.endedAt.timeIntervalSince(record.startedAt), 0)

        if !record.isSavedToLibrary {
            do {
                record.urls = try promoteMediaURLsToSavedLibrary(record.urls)
                record.isSavedToLibrary = true
            } catch {
                DispatchQueue.main.async {
                    self.alertMessage = error.localizedDescription
                    self.detailText = "Could not promote one of the retro buffer clips into the saved library."
                    self.showAlert = true
                }
                return
            }
        }

        for mediaURL in record.urls {
            if DashClipMetadataStore.load(for: mediaURL) != nil {
                DashClipMetadataStore.update(for: mediaURL) { metadata in
                    metadata.add(tags: mergedTags, protected: true)
                }
                continue
            }

            persistClipMetadata(
                for: mediaURL,
                source: .recordingSegment,
                startedAt: record.startedAt,
                endedAt: record.endedAt,
                durationSeconds: durationSeconds,
                snapshot: record.captureSnapshot,
                protected: true,
                eventTags: mergedTags
            )
        }

        record.eventTags = mergedTags
        recentFinishedSegments[index] = record
    }

    private func pruneExpiredRetroBufferSegments(referenceDate: Date = Date()) {
        let cutoff = referenceDate.addingTimeInterval(-retroBufferLength.seconds)
        var expiredBufferRecords: [DashFinishedSegmentRecord] = []

        recentFinishedSegments.removeAll { record in
            guard record.endedAt < cutoff else { return false }
            if !record.isSavedToLibrary {
                expiredBufferRecords.append(record)
            }
            return true
        }

        for record in expiredBufferRecords {
            for url in record.urls {
                try? FileManager.default.removeItem(at: url)
                DashClipMetadataStore.remove(for: url)
            }
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

            let isProtectedByMetadata = DashClipMetadataStore.load(for: url)?.isProtected ?? false

            if !protectedURLs.contains(url) && !isProtectedByMetadata {
                entries.append((url: url, date: date, size: size))
            }
        }

        guard totalSize > storageCap.bytes else { return }

        let sorted = entries.sorted { $0.date < $1.date }
        var runningSize = totalSize

        for entry in sorted where runningSize > storageCap.bytes {
            do {
                try FileManager.default.removeItem(at: entry.url)
                DashClipMetadataStore.remove(for: entry.url)
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
        loopStatusText = "Loop \(clipLength.shortLabel) • buffer \(retroBufferLength.shortLabel) • cap \(storageCap.shortLabel) • used \(usedText)"
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
