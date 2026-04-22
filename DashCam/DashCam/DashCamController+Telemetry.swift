//
//  DashCamController+Telemetry.swift
//  DashCam
//
//  Created by Muhanned Alkhafaji on 3/1/26.
//

import Foundation
import CoreLocation

extension DashCamController {

    private static let liveClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    // clock and gps

    func startLiveClock() {
        updateClockText()
        liveClockTimer?.invalidate()
        liveClockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateClockText()
        }
    }

    func updateClockText() {
        currentClockText = Self.liveClockFormatter.string(from: Date())
        updateLiveStampText()
    }

    func startAncillaryServicesIfNeeded() {
        guard isSceneActive else { return }
        guard !hasStartedAncillaryServices else { return }

        hasStartedAncillaryServices = true
        ancillaryServicesStartWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isSceneActive else { return }

            self.locationManager.start()
            self.updateConvoyConnectionState()
            self.updateCrashDetectionState()
            self.evaluateAutoStartStop(with: self.locationManager.speedMetersPerSecond)
            self.ancillaryServicesStartWorkItem = nil
        }

        ancillaryServicesStartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    func updateLiveStampText() {
        let gps = locationManager.coordinateText
        let mph = max(0, (locationManager.speedMetersPerSecond ?? 0) * 2.2369362921)
        let speed = String(format: "%.1f mph", mph)
        let compass = showCompass ? compassText ?? "" : ""
        let stampParts = [currentClockText, gps, compass, speed].filter { !$0.isEmpty }
        liveStampText = stampParts.joined(separator: " • ")
        cachedStampKey = ""
        cachedStampOverlay = nil
    }

    // convoy

    // gate websocket connection by scene state + user setting

    func updateConvoyConnectionState() {
        guard isSceneActive else {
            convoyPresenceService.disconnect()
            convoyStatusText = "Convoy paused in background"
            return
        }

        guard convoyEnabled else {
            convoyPresenceService.disconnect()
            convoyStatusText = "Convoy off"
            return
        }

        convoyPresenceService.connectIfNeeded(
            serverURLString: convoyServerURL,
            sessionCode: convoySessionCode,
            userID: convoyUserID,
            name: convoyDisplayName
        )
    }

    // send live location updates to convoy service

    func publishConvoyLocationIfNeeded(_ location: CLLocation?) {
        guard convoyEnabled else { return }
        guard let location else { return }

        convoyPresenceService.publishLocation(
            location,
            headingDegrees: locationManager.headingDegrees,
            speedMetersPerSecond: locationManager.speedMetersPerSecond
        )
    }

    // crash detection

    // start or stop the detector based on scene state and user settings

    func updateCrashDetectionState() {
        guard isSceneActive else {
            crashDetector.stop()
            return
        }

        guard crashDetectionEnabled else {
            crashDetector.stop()
            return
        }

        crashDetector.start(sensitivity: crashSensitivity)
    }

    // impact event handler

    // The hidden rolling buffer means crash detection can now preserve footage
    // even when the user never tapped Record. If the buffer is armed, treat the
    // crash signal like a retro-save event and protect the overlapping segments.

    func handlePotentialCrashImpact(magnitudeG: Double) {
        let text = String(format: "Possible crash detected (%.2fg)", magnitudeG)
        crashStatusText = text
        detailText = text

        if isLoopBufferActive {
            markCurrentMoment(tags: [.crash], detailMessage: "Crash event detected. Buffered clips around the impact will stay protected.")
        }
    }
}
