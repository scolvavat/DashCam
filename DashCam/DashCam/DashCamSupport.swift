//
//  DashCamSupport.swift
//  DashCam
//
//  Created by Muhanned Alkhafaji on 3/1/26.
//

import SwiftUI
import AVFoundation
import CoreLocation
import Combine

// preview bridge

// this file holds the small support pieces that the main camera file depends on

// i pulled these out first because they are low risk compared to the recorder and controller logic

// the goal here is to slowly peel support types out of the mega file without touching the fragile camera pipeline yet

// rear camera preview bridge

// this representable hosts the live rear camera preview layer inside swiftui

// the controller still owns the actual capture session and tells this preview which layer to attach to

struct RearCameraPreview: UIViewRepresentable {
    
    // main dashcam controller
    
    // this is observed so the preview can ask the controller to reattach the layer when swiftui updates
    
    @ObservedObject var controller: DashCamController
    
    // make the backing uiview once
    
    // this creates a preview view whose root layer is AVCaptureVideoPreviewLayer
    
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.videoGravity = .resizeAspectFill
        controller.attachPreviewLayer(view.previewLayer)
        return view
    }
    
    // update the existing uiview when swiftui refreshes the tree
    
    // this reattaches the same preview layer back to the controller if needed
    
    func updateUIView(_ uiView: PreviewView, context: Context) {
        controller.attachPreviewLayer(uiView.previewLayer)
    }
}

// preview hosting view

// this uiview's main layer is an AVCaptureVideoPreviewLayer so avfoundation can render directly into it

final class PreviewView: UIView {
    
    // swap the default CALayer for AVCaptureVideoPreviewLayer
    
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }
    
    // typed convenience accessor for the backing preview layer
    
    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

// recording mode

// this controls whether the app saves one combined pip file or two separate camera files

enum RecordingMode: String, CaseIterable, Identifiable {
    
    // one combined rear video with the front video as a small overlay
    
    case pipSingleFile
    
    // two separate output files, one for rear and one for front
    
    case dualSeparateFiles
    
    // swiftui identity for pickers and foreach
    
    var id: String { rawValue }

    private var ui: (label: String, short: String) {
        switch self {
        case .pipSingleFile:
            return ("PiP single file", "PiP file")
        case .dualSeparateFiles:
            return ("Dual separate files", "Dual files")
        }
    }

    // full label shown in settings or menus

    var label: String { ui.label }

    // shorter label used in tighter ui spots

    var shortLabel: String { ui.short }
}

// video quality

// this controls the output canvas and the approximate target bitrate for each recorded segment

enum DashVideoQuality: String, CaseIterable, Identifiable {
    
    // 480p output
    
    case p480
    
    // 720p output
    
    case p720
    
    // 1080p output
    
    case p1080
    
    // 4k rear focused output
    
    case p4K
    
    // swiftui identity for menus and pickers
    
    var id: String { rawValue }

    private var config: (label: String, size: CGSize, bitRate: Int) {
        switch self {
        case .p480:
            return ("480p", CGSize(width: 854, height: 480), 1_500_000)
        case .p720:
            return ("720p", CGSize(width: 1280, height: 720), 3_000_000)
        case .p1080:
            return ("1080p", CGSize(width: 1920, height: 1080), 6_000_000)
        case .p4K:
            return ("4K rear", CGSize(width: 3840, height: 2160), 14_000_000)
        }
    }

    // user facing label

    var label: String { config.label }

    // render canvas size used by the writer

    var size: CGSize { config.size }

    // target bitrate for the output writer

    var bitRate: Int { config.bitRate }
    
    // helper quality for the front stream when rear is using 4k
    
    var frontCompanionQuality: DashVideoQuality {
        switch self {
        case .p4K:
            return .p720
        default:
            return self
        }
    }
    
    // convenience flag for code paths that want special rear-first 4k handling
    
    var usesRearOnly4KBehavior: Bool {
        self == .p4K
    }
}

// rear lens option

// this controls which physical rear lens we target when configuring the session

enum RearLensOption: String, CaseIterable, Identifiable {

    case wide
    case ultraWide

    var id: String { rawValue }

    private var ui: (label: String, short: String) {
        switch self {
        case .wide:
            return ("Rear 1x", "1x")
        case .ultraWide:
            return ("Rear 0.5x", "0.5x")
        }
    }

    var label: String { ui.label }
    var shortLabel: String { ui.short }
}

// frame rate

// this controls the target recording cadence used when choosing capture formats

enum DashFrameRate: Int, CaseIterable, Identifiable {

    // cinematic low power option

    case fps24 = 24

    // standard video option

    case fps30 = 30

    // smoother motion when the device format can sustain it

    case fps60 = 60

    var id: Int { rawValue }

    var framesPerSecond: Double {
        Double(rawValue)
    }

    var label: String {
        "\(rawValue) fps"
    }
}

// bitrate profile

// this lets you tune encoder load without changing resolution/fps settings

enum DashBitrateProfile: String, CaseIterable, Identifiable {

    case veryLow
    case low
    case balanced
    case high

    var id: String { rawValue }

    private var config: (label: String, multiplier: Double) {
        switch self {
        case .veryLow:
            return ("Very low", 0.4)
        case .low:
            return ("Low", 0.55)
        case .balanced:
            return ("Balanced", 0.75)
        case .high:
            return ("High", 1.0)
        }
    }

    var label: String { config.label }
    var multiplier: Double { config.multiplier }
}

// crash sensitivity

// this controls how strong a motion spike must be before we flag a likely impact

enum DashCrashSensitivity: String, CaseIterable, Identifiable {

    case low
    case balanced
    case high

    var id: String { rawValue }

    private var config: (label: String, threshold: Double) {
        switch self {
        case .low:
            return ("Low sensitivity", 2.6)
        case .balanced:
            return ("Balanced sensitivity", 2.1)
        case .high:
            return ("High sensitivity", 1.7)
        }
    }

    var label: String { config.label }

    // threshold in g-force from user acceleration magnitude

    var impactThresholdG: Double { config.threshold }
}

// clip length

// this controls how long each rolling segment lasts before the app starts a new file

enum DashClipLength: Int, CaseIterable, Identifiable {
    
    // 15 second segment
    
    case s15 = 15
    
    // 30 second segment
    
    case s30 = 30
    
    // 60 second segment
    
    case s60 = 60
    
    // 120 second segment
    
    case s120 = 120
    
    // swiftui identity
    
    var id: Int { rawValue }

    private var ui: (label: String, short: String) {
        switch self {
        case .s15:
            return ("15 second clips", "15s clips")
        case .s30:
            return ("30 second clips", "30s clips")
        case .s60:
            return ("1 minute clips", "1m clips")
        case .s120:
            return ("2 minute clips", "2m clips")
        }
    }
    
    // seconds as timeinterval for timers and scheduling
    
    var seconds: TimeInterval {
        TimeInterval(rawValue)
    }
    
    // full label for settings
    
    var label: String { ui.label }
    
    // short label for compact ui chips
    
    var shortLabel: String { ui.short }
}

// retro buffer length

// this controls how far back the retro-save button should reach when the user
// taps Record after something already happened.

enum DashRetroBufferLength: Int, CaseIterable, Identifiable {

    case s30 = 30
    case s60 = 60
    case s120 = 120

    var id: Int { rawValue }

    private var ui: (label: String, short: String) {
        switch self {
        case .s30:
            return ("30 second buffer", "30s")
        case .s60:
            return ("1 minute buffer", "1m")
        case .s120:
            return ("2 minute buffer", "2m")
        }
    }

    var seconds: TimeInterval {
        TimeInterval(rawValue)
    }

    var label: String { ui.label }
    var shortLabel: String { ui.short }
}

// storage cap

// this controls how much local disk space the rolling loop is allowed to use before old clips get deleted

enum DashStorageCap: Int, CaseIterable, Identifiable {
    
    // 2 gb local cap
    
    case gb2 = 2
    
    // 5 gb local cap
    
    case gb5 = 5
    
    // 10 gb local cap
    
    case gb10 = 10
    
    // 20 gb local cap
    
    case gb20 = 20
    
    // swiftui identity
    
    var id: Int { rawValue }

    private var ui: (label: String, short: String) {
        switch self {
        case .gb2:
            return ("2 GB cap", "2 GB")
        case .gb5:
            return ("5 GB cap", "5 GB")
        case .gb10:
            return ("10 GB cap", "10 GB")
        case .gb20:
            return ("20 GB cap", "20 GB")
        }
    }
    
    // raw byte count used by cleanup logic
    
    var bytes: Int64 {
        Int64(rawValue) * 1_000_000_000
    }
    
    // full label for settings
    
    var label: String { ui.label }
    
    // short label for compact ui
    
    var shortLabel: String { ui.short }
}

enum DashClipSource: String, Codable, Hashable {
    case recordingSegment
    case snapshotPhoto
}

enum DashClipEventTag: String, Codable, Hashable, CaseIterable, Identifiable {
    case protectedClip
    case manualSave
    case crash
    case routeLinked

    var id: String { rawValue }

    var title: String {
        switch self {
        case .protectedClip:
            return "Protected"
        case .manualSave:
            return "Manual Save"
        case .crash:
            return "Crash"
        case .routeLinked:
            return "Route"
        }
    }
}

struct DashClipCoordinate: Codable, Hashable {
    let latitude: Double
    let longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct DashClipRouteContext: Codable, Hashable {
    let title: String
    let subtitle: String

    var line: String {
        subtitle.isEmpty ? title : "\(title) • \(subtitle)"
    }
}

struct DashClipCaptureSnapshot: Codable, Hashable {
    let recordedAt: Date
    let coordinate: DashClipCoordinate?
    let speedMetersPerSecond: Double?
    let headingDegrees: Double?
    let route: DashClipRouteContext?
}

struct DashClipMetadata: Codable, Hashable {
    let mediaFileName: String
    let source: DashClipSource
    let startedAt: Date
    let endedAt: Date
    let recordingMode: String?
    let quality: String?
    let rearLens: String?
    let durationSeconds: Double?
    let captureSnapshot: DashClipCaptureSnapshot
    var isProtected: Bool
    var eventTags: [DashClipEventTag]

    var effectiveTags: [DashClipEventTag] {
        var tags = eventTags
        if isProtected && !tags.contains(.protectedClip) {
            tags.insert(.protectedClip, at: 0)
        }
        return tags
    }

    func contains(_ tag: DashClipEventTag) -> Bool {
        effectiveTags.contains(tag)
    }

    mutating func add(tags newTags: [DashClipEventTag], protected shouldProtect: Bool) {
        isProtected = isProtected || shouldProtect
        for tag in newTags where !eventTags.contains(tag) {
            eventTags.append(tag)
        }
        if isProtected && !eventTags.contains(.protectedClip) {
            eventTags.insert(.protectedClip, at: 0)
        }
    }
}

enum DashClipMetadataStore {
    static func metadataURL(for mediaURL: URL) -> URL {
        mediaURL.appendingPathExtension("json")
    }

    static func load(for mediaURL: URL) -> DashClipMetadata? {
        let url = metadataURL(for: mediaURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DashClipMetadata.self, from: data)
    }

    static func save(_ metadata: DashClipMetadata, for mediaURL: URL) throws {
        let url = metadataURL(for: mediaURL)
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: url, options: .atomic)
    }

    static func update(for mediaURL: URL, mutate: (inout DashClipMetadata) -> Void) {
        guard var metadata = load(for: mediaURL) else { return }
        mutate(&metadata)
        try? save(metadata, for: mediaURL)
    }

    static func remove(for mediaURL: URL) {
        try? FileManager.default.removeItem(at: metadataURL(for: mediaURL))
    }
}

// location manager

// this holds gps and speed monitoring in one place so the main controller can subscribe to the values it cares about

final class DashLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    
    // latest coordinate text used by the ui and the stamp line
    
    @Published var coordinateText: String = "GPS waiting..."

    // latest raw coordinate used by map tracking

    // nil means no fix has arrived yet

    @Published var currentCoordinate: CLLocationCoordinate2D?

    // full last location sample for services that need timestamp and distance math

    @Published var latestLocation: CLLocation?
    
    // latest speed in meters per second
    
    // nil means no good reading right now
    
    @Published var speedMetersPerSecond: Double?

    // latest magnetic heading in degrees

    // nil means the device is not providing a reliable heading yet

    @Published var headingDegrees: Double?

    // simple breadcrumb trail for map overlay

    // this keeps a short route history locally so the map still has useful context even when tiles are offline

    @Published var breadcrumbCoordinates: [CLLocationCoordinate2D] = []
    
    // apple location manager
    
    private let manager = CLLocationManager()
    private let breadcrumbDistanceThreshold: CLLocationDistance = 8
    private let breadcrumbMaxPoints: Int = 900
    
    // setup the manager once
    
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.activityType = .automotiveNavigation
        manager.headingFilter = 5
    }
    
    // begin receiving location updates if permission already exists
    
    // otherwise request when in use permission
    
    func start() {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            startLocationUpdates()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            resetForDeniedPermission()
        }
    }
    
    // stop foreground location updates
    
    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        latestLocation = nil
        speedMetersPerSecond = nil
        headingDegrees = nil
    }
    
    // react to permission changes
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            startLocationUpdates()
        case .notDetermined:
            break
        default:
            resetForDeniedPermission()
        }
    }
    
    // handle each new location reading
    
    // this updates both the coordinate display text and the live speed used by auto start
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        DispatchQueue.main.async {
            self.coordinateText = String(format: "%.5f, %.5f", location.coordinate.latitude, location.coordinate.longitude)
            self.currentCoordinate = location.coordinate
            self.latestLocation = location
            self.speedMetersPerSecond = location.speed >= 0 ? location.speed : nil

            self.appendBreadcrumbIfNeeded(for: location)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        DispatchQueue.main.async {
            self.headingDegrees = heading >= 0 ? heading : nil
        }
    }

    private func startLocationUpdates() {
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    private func resetForDeniedPermission() {
        coordinateText = "GPS permission denied"
        currentCoordinate = nil
        latestLocation = nil
        speedMetersPerSecond = nil
        headingDegrees = nil
    }

    private func appendBreadcrumbIfNeeded(for location: CLLocation) {
        if let last = breadcrumbCoordinates.last {
            let lastLocation = CLLocation(latitude: last.latitude, longitude: last.longitude)
            guard location.distance(from: lastLocation) >= breadcrumbDistanceThreshold else { return }
        }

        breadcrumbCoordinates.append(location.coordinate)
        if breadcrumbCoordinates.count > breadcrumbMaxPoints {
            breadcrumbCoordinates.removeFirst(breadcrumbCoordinates.count - breadcrumbMaxPoints)
        }
    }
}
