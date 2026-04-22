//
//  DashCamPresenceAndCrash.swift
//  DashCam
//
//  Created by Muhanned Alkhafaji on 3/1/26.
//

import Foundation
import CoreLocation
import CoreMotion

// friend presence model

// one live friend marker on the convoy map

struct DashFriendPresence: Identifiable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let speedMetersPerSecond: Double?
    let headingDegrees: Double?
    let updatedAt: Date
}

// convoy websocket service

// this runs a tiny json protocol over websockets for live friend map presence

final class DashConvoyPresenceService: NSObject {

    var onFriendsChanged: (([DashFriendPresence]) -> Void)?
    var onStatusChanged: ((String) -> Void)?

    private var webSocketTask: URLSessionWebSocketTask?
    private lazy var urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    private var currentServerURLString: String = ""
    private var currentSessionCode: String = ""
    private var currentUserID: String = ""
    private var currentName: String = ""
    private var isConnected: Bool = false

    private var friendByID: [String: DashFriendPresence] = [:]
    private var lastSentLocation: CLLocation?
    private var lastSentAt: Date?

    private let sendInterval: TimeInterval = 1.0
    private let sendDistanceMeters: CLLocationDistance = 6

    func connectIfNeeded(serverURLString: String, sessionCode: String, userID: String, name: String) {
        let trimmedURL = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSession = sessionCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedURL.isEmpty else {
            setStatus("Convoy off • add server URL")
            disconnect()
            return
        }

        guard !trimmedSession.isEmpty else {
            setStatus("Convoy off • add session code")
            disconnect()
            return
        }

        guard let url = URL(string: trimmedURL) else {
            setStatus("Convoy off • invalid server URL")
            disconnect()
            return
        }

        let needsReconnect = currentServerURLString != trimmedURL || currentSessionCode != trimmedSession || currentUserID != userID
        currentServerURLString = trimmedURL
        currentSessionCode = trimmedSession
        currentUserID = userID
        currentName = trimmedName.isEmpty ? "Driver" : trimmedName

        if webSocketTask == nil || needsReconnect {
            disconnect()
            setStatus("Convoy connecting...")
            let task = urlSession.webSocketTask(with: url)
            webSocketTask = task
            task.resume()
            receiveLoop()
        }
    }

    func disconnect() {
        isConnected = false

        if webSocketTask != nil {
            sendLeave()
            webSocketTask?.cancel(with: .goingAway, reason: nil)
        }

        webSocketTask = nil
        friendByID.removeAll()
        lastSentLocation = nil
        lastSentAt = nil
        DispatchQueue.main.async {
            self.onFriendsChanged?([])
        }
    }

    func publishLocation(_ location: CLLocation, headingDegrees: Double?, speedMetersPerSecond: Double?) {
        guard isConnected else { return }

        let now = Date()
        if let lastSentAt, now.timeIntervalSince(lastSentAt) < sendInterval {
            if let lastSentLocation, location.distance(from: lastSentLocation) < sendDistanceMeters {
                return
            }
        }

        lastSentAt = now
        lastSentLocation = location

        let payload: [String: Any] = [
            "type": "update",
            "session": currentSessionCode,
            "userId": currentUserID,
            "name": currentName,
            "lat": location.coordinate.latitude,
            "lng": location.coordinate.longitude,
            "speedMPS": speedMetersPerSecond ?? NSNull(),
            "heading": headingDegrees ?? NSNull(),
            "timestamp": Int(now.timeIntervalSince1970 * 1000)
        ]

        sendJSON(payload)
    }

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .failure:
                self.setStatus("Convoy disconnected")
                self.disconnect()
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }

                self.receiveLoop()
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return
        }

        switch type {
        case "snapshot":
            guard let members = object["members"] as? [[String: Any]] else { return }
            friendByID.removeAll()
            for raw in members {
                guard let presence = parsePresence(raw), presence.id != currentUserID else { continue }
                friendByID[presence.id] = presence
            }
            emitFriendSnapshot()
        case "presence":
            guard let raw = object["member"] as? [String: Any],
                  let presence = parsePresence(raw),
                  presence.id != currentUserID else { return }
            friendByID[presence.id] = presence
            emitFriendSnapshot()
        case "left":
            guard let userID = object["userId"] as? String else { return }
            friendByID.removeValue(forKey: userID)
            emitFriendSnapshot()
        case "status":
            if let message = object["message"] as? String {
                setStatus(message)
            }
        default:
            break
        }
    }

    private func parsePresence(_ raw: [String: Any]) -> DashFriendPresence? {
        guard let id = raw["userId"] as? String,
              let lat = raw["lat"] as? Double,
              let lng = raw["lng"] as? Double else {
            return nil
        }

        let name = (raw["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Driver"
        let speed = raw["speedMPS"] as? Double
        let heading = raw["heading"] as? Double
        let timeMS = raw["timestamp"] as? Double ?? Double(Int(Date().timeIntervalSince1970 * 1000))
        let date = Date(timeIntervalSince1970: timeMS / 1000.0)

        return DashFriendPresence(
            id: id,
            name: name,
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
            speedMetersPerSecond: speed,
            headingDegrees: heading,
            updatedAt: date
        )
    }

    private func emitFriendSnapshot() {
        let friends = friendByID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        DispatchQueue.main.async {
            self.onFriendsChanged?(friends)
            self.setStatus("Convoy live • \(friends.count) friend\(friends.count == 1 ? "" : "s")")
        }
    }

    private func sendJoin() {
        let payload: [String: Any] = [
            "type": "join",
            "session": currentSessionCode,
            "userId": currentUserID,
            "name": currentName
        ]
        sendJSON(payload)
    }

    private func sendLeave() {
        let payload: [String: Any] = [
            "type": "leave",
            "session": currentSessionCode,
            "userId": currentUserID
        ]
        sendJSON(payload)
    }

    private func sendJSON(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        webSocketTask?.send(.string(text)) { _ in }
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async {
            self.onStatusChanged?(text)
        }
    }
}

extension DashConvoyPresenceService: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol selectedProtocol: String?) {
        isConnected = true
        setStatus("Convoy connected")
        sendJoin()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        isConnected = false
        setStatus("Convoy disconnected")
    }
}

// crash detector

// lightweight foreground detector using CoreMotion user acceleration magnitude

final class DashCrashDetector {

    var onStatusChanged: ((String) -> Void)?
    var onImpactDetected: ((Double) -> Void)?

    private let motionManager = CMMotionManager()
    private let queue = OperationQueue()
    private var lastImpactAt: Date?
    private let impactDebounceSeconds: TimeInterval = 3

    init() {
        queue.name = "dashcam.crash.detector.queue"
        queue.qualityOfService = .userInitiated
    }

    func start(sensitivity: DashCrashSensitivity) {
        guard motionManager.isDeviceMotionAvailable else {
            DispatchQueue.main.async {
                self.onStatusChanged?("Crash detection unavailable on this device")
            }
            return
        }

        stop()

        let threshold = sensitivity.impactThresholdG
        motionManager.deviceMotionUpdateInterval = 1.0 / 20.0
        motionManager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }

            let x = motion.userAcceleration.x
            let y = motion.userAcceleration.y
            let z = motion.userAcceleration.z
            let magnitude = sqrt((x * x) + (y * y) + (z * z))

            guard magnitude >= threshold else { return }

            let now = Date()
            if let lastImpactAt, now.timeIntervalSince(lastImpactAt) < impactDebounceSeconds {
                return
            }

            lastImpactAt = now
            DispatchQueue.main.async {
                self.onImpactDetected?(magnitude)
            }
        }

        DispatchQueue.main.async {
            self.onStatusChanged?("Crash detection on (\(sensitivity.label.lowercased()))")
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        DispatchQueue.main.async {
            self.onStatusChanged?("Crash detection off")
        }
    }
}
