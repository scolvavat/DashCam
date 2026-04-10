import SwiftUI
import AVFoundation
import UIKit

extension DashCamController {

    // preview hookup

    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        sessionQueue.async {
            self.previewLayer = layer
            layer.videoGravity = .resizeAspectFill

            if self.multiCamSupported {
                self.attachMultiCamPreviewIfNeeded(to: layer)
            } else if layer.session !== self.session {
                layer.session = self.session
            }

            self.applyPreviewMirrorState(to: layer.connection)
            DispatchQueue.main.async {
                self.applyPreviewRotationNow()
            }
        }
    }

    // permissions

    func requestPermissionsThenStart() {
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

    func requestAudioThenConfigure() {
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

    func configureIfNeededAndRun(includeAudio: Bool) {
        sessionQueue.async {
            if self.isStartingSession {
                return
            }

            self.isStartingSession = true
            defer { self.isStartingSession = false }

            do {
                if !self.didConfigureSession {
                    try self.configureSession(includeAudio: includeAudio)
                    self.didConfigureSession = true
                }

                if !self.session.isRunning {
                    self.session.startRunning()
                }

                self.attachPreviewIfPossible()

                DispatchQueue.main.async {
                    self.isRunning = self.session.isRunning
                    self.resetCaptureReadiness(includeAudio: self.audioInput != nil)
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

    func prepareAudioSession() {
        if hasPreparedAudioSession {
            return
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
            try audioSession.setActive(true)
            hasPreparedAudioSession = true
        } catch {
            DispatchQueue.main.async {
                self.savedClipText = "Mic session warning: \(error.localizedDescription)"
            }
        }
    }

    // session setup

    func rearCaptureDeviceForCurrentLens() -> AVCaptureDevice? {
        switch rearLens {
        case .wide:
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        case .ultraWide:
            return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        }
    }

    func configureSession(includeAudio: Bool) throws {
        if multiCamSupported {
            try configureMultiCamSession(includeAudio: includeAudio)
        } else {
            try configureSingleCamSession(includeAudio: includeAudio)
        }
    }

    func configureMultiCamSession(includeAudio: Bool) throws {
        guard let multiSession = session as? AVCaptureMultiCamSession else {
            throw DashCamError.couldNotCreateMultiCamSession
        }

        multiSession.beginConfiguration()
        defer { multiSession.commitConfiguration() }

        guard let rearDevice = rearCaptureDeviceForCurrentLens() else {
            throw DashCamError.noRearCamera
        }

        guard let frontDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw DashCamError.noFrontCamera
        }

        let rearMaxWidth = quality.usesRearOnly4KBehavior ? Int32(quality.size.width) : Int32(quality.size.width)
        let frontMaxWidth = frontTargetQuality.size.width

        try setMultiCamFormatIfPossible(
            for: rearDevice,
            maxWidth: rearMaxWidth,
            targetFrameRate: rearTargetFrameRate
        )
        try setMultiCamFormatIfPossible(
            for: frontDevice,
            maxWidth: Int32(frontMaxWidth),
            targetFrameRate: frontTargetFrameRate
        )

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

    func configureSingleCamSession(includeAudio: Bool) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard let rearDevice = rearCaptureDeviceForCurrentLens() else {
            throw DashCamError.noRearCamera
        }

        try setSingleCamFormatIfPossible(
            for: rearDevice,
            maxWidth: Int32(quality.size.width),
            targetFrameRate: rearTargetFrameRate
        )

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

    func configureVideoOutput(_ output: AVCaptureVideoDataOutput) {
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)
    }

    // preview connection

    func attachPreviewIfPossible() {
        guard let previewLayer else { return }

        if multiCamSupported {
            attachMultiCamPreviewIfNeeded(to: previewLayer)
        } else if previewLayer.session !== session {
            previewLayer.session = session
        }

        applyPreviewMirrorState(to: previewLayer.connection)
        DispatchQueue.main.async {
            self.applyPreviewRotationNow()
        }
    }

    func attachMultiCamPreviewIfNeeded(to layer: AVCaptureVideoPreviewLayer) {
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

    func applyPreviewMirrorState(to connection: AVCaptureConnection?) {
        guard let connection else { return }

        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    func applyPreviewRotationNow() {
        guard let connection = previewLayer?.connection else { return }
        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(rearPreviewAngle) {
                connection.videoRotationAngle = rearPreviewAngle
            }
        }
    }

    // orientation tracking

    func startOrientationTracking() {
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

    func updateCurrentAngles() {
        let orientation = currentInterfaceOrDeviceOrientation()
        let angles = anglesForOrientation(orientation)
        rearPreviewAngle = angles.preview
        rearCaptureAngle = angles.rearCapture
        frontCaptureAngle = angles.frontCapture
        applyPreviewRotationNow()
    }

    func currentInterfaceOrDeviceOrientation() -> UIInterfaceOrientation {
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

    func anglesForOrientation(_ orientation: UIInterfaceOrientation) -> (preview: CGFloat, rearCapture: CGFloat, frontCapture: CGFloat) {
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

        let previewAngle = normalizedAngle(baseAngle)
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

    // device format

    func applyCurrentCaptureFormatsIfPossible() {
        sessionQueue.async {
            guard self.didConfigureSession else { return }

            do {
                if let rearDevice = self.rearVideoInput?.device {
                    if self.multiCamSupported {
                        try self.setMultiCamFormatIfPossible(
                            for: rearDevice,
                            maxWidth: Int32(self.quality.size.width),
                            targetFrameRate: self.rearTargetFrameRate
                        )
                    } else {
                        try self.setSingleCamFormatIfPossible(
                            for: rearDevice,
                            maxWidth: Int32(self.quality.size.width),
                            targetFrameRate: self.rearTargetFrameRate
                        )
                    }
                }

                if self.multiCamSupported, let frontDevice = self.frontVideoInput?.device {
                    try self.setMultiCamFormatIfPossible(
                        for: frontDevice,
                        maxWidth: Int32(self.frontTargetQuality.size.width),
                        targetFrameRate: self.frontTargetFrameRate
                    )
                }

                DispatchQueue.main.async {
                    let rearFPS = Int(self.rearTargetFrameRate)
                    let frontFPS = Int(self.frontTargetFrameRate)

                    if self.multiCamSupported {
                        if self.quality == .p4K {
                            self.detailText = "4K rear mode ready. Rear capped to \(rearFPS) fps. Front capped to \(frontFPS) fps."
                        } else {
                            self.detailText = "Capture quality updated. Rear capped to \(rearFPS) fps. Front capped to \(frontFPS) fps."
                        }
                    } else {
                        self.detailText = self.quality == .p4K ? "4K rear mode ready. Rear capped to \(rearFPS) fps." : "Capture quality updated. Rear capped to \(rearFPS) fps."
                    }
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

    func setMultiCamFormatIfPossible(for device: AVCaptureDevice, maxWidth: Int32, targetFrameRate: Double) throws {
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

    func setSingleCamFormatIfPossible(for device: AVCaptureDevice, maxWidth: Int32, targetFrameRate: Double) throws {
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
}
