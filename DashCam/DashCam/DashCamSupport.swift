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
    
    // full label shown in settings or menus
    
    var label: String {
        switch self {
        case .pipSingleFile:
            return "PiP single file"
        case .dualSeparateFiles:
            return "Dual separate files"
        }
    }
    
    // shorter label used in tighter ui spots
    
    var shortLabel: String {
        switch self {
        case .pipSingleFile:
            return "PiP file"
        case .dualSeparateFiles:
            return "Dual files"
        }
    }
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
    
    // user facing label
    
    var label: String {
        switch self {
        case .p480:
            return "480p"
        case .p720:
            return "720p"
        case .p1080:
            return "1080p"
        case .p4K:
            return "4K rear"
        }
    }
    
    // render canvas size used by the writer
    
    var size: CGSize {
        switch self {
        case .p480:
            return CGSize(width: 854, height: 480)
        case .p720:
            return CGSize(width: 1280, height: 720)
        case .p1080:
            return CGSize(width: 1920, height: 1080)
        case .p4K:
            return CGSize(width: 3840, height: 2160)
        }
    }
    
    // target bitrate for the output writer
    
    var bitRate: Int {
        switch self {
        case .p480:
            return 2_500_000
        case .p720:
            return 5_500_000
        case .p1080:
            return 10_000_000
        case .p4K:
            return 24_000_000
        }
    }
    
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
    
    // seconds as timeinterval for timers and scheduling
    
    var seconds: TimeInterval {
        TimeInterval(rawValue)
    }
    
    // full label for settings
    
    var label: String {
        switch self {
        case .s15:
            return "15 second clips"
        case .s30:
            return "30 second clips"
        case .s60:
            return "1 minute clips"
        case .s120:
            return "2 minute clips"
        }
    }
    
    // short label for compact ui chips
    
    var shortLabel: String {
        switch self {
        case .s15:
            return "15s clips"
        case .s30:
            return "30s clips"
        case .s60:
            return "1m clips"
        case .s120:
            return "2m clips"
        }
    }
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
    
    // raw byte count used by cleanup logic
    
    var bytes: Int64 {
        Int64(rawValue) * 1_000_000_000
    }
    
    // full label for settings
    
    var label: String {
        switch self {
        case .gb2:
            return "2 GB cap"
        case .gb5:
            return "5 GB cap"
        case .gb10:
            return "10 GB cap"
        case .gb20:
            return "20 GB cap"
        }
    }
    
    // short label for compact ui
    
    var shortLabel: String {
        switch self {
        case .gb2:
            return "2 GB"
        case .gb5:
            return "5 GB"
        case .gb10:
            return "10 GB"
        case .gb20:
            return "20 GB"
        }
    }
}

// location manager

// this holds gps and speed monitoring in one place so the main controller can subscribe to the values it cares about

final class DashLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    
    // latest coordinate text used by the ui and the stamp line
    
    @Published var coordinateText: String = "GPS waiting..."
    
    // latest speed in meters per second
    
    // nil means no good reading right now
    
    @Published var speedMetersPerSecond: Double?

    // latest magnetic heading in degrees

    // nil means the device is not providing a reliable heading yet

    @Published var headingDegrees: Double?
    
    // apple location manager
    
    private let manager = CLLocationManager()
    
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
            manager.startUpdatingLocation()
            if CLLocationManager.headingAvailable() {
                manager.startUpdatingHeading()
            }
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            coordinateText = "GPS permission denied"
            speedMetersPerSecond = nil
            headingDegrees = nil
        }
    }
    
    // stop foreground location updates
    
    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        speedMetersPerSecond = nil
        headingDegrees = nil
    }
    
    // react to permission changes
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
            if CLLocationManager.headingAvailable() {
                manager.startUpdatingHeading()
            }
        case .notDetermined:
            break
        default:
            coordinateText = "GPS permission denied"
            speedMetersPerSecond = nil
            headingDegrees = nil
        }
    }
    
    // handle each new location reading
    
    // this updates both the coordinate display text and the live speed used by auto start
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        coordinateText = String(format: "%.5f, %.5f", location.coordinate.latitude, location.coordinate.longitude)
        speedMetersPerSecond = location.speed >= 0 ? location.speed : nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        headingDegrees = heading >= 0 ? heading : nil
    }
}
