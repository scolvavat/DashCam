import AVFoundation

// capture delegates

// keep every sample callback on the same serial queue so writer state stays predictable

extension DashCamController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    // keep front pip updates lighter than camera frame rate
    // the combo writer only needs a recent frame, not every front frame.

    func shouldUpdateFrontPiPBufferNow() -> Bool {
        let now = CACurrentMediaTime()
        let minimumInterval: CFTimeInterval

        if isRecording && frameRate == .fps60 {
            minimumInterval = 0.08
        } else if isRecording {
            minimumInterval = 0.05
        } else {
            minimumInterval = 0.0
        }

        if now - lastFrontPiPBufferPush < minimumInterval {
            return false
        }

        lastFrontPiPBufferPush = now
        return true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === rearVideoOutput {
            handleRearVideoSample(sampleBuffer)
        } else if output === frontVideoOutput {
            handleFrontVideoSample(sampleBuffer)
        } else if output === audioOutput {
            handleAudioSample(sampleBuffer)
        }
    }

    // avoid doing expensive ci rendering work when the writer is backpressured.
    // at 4k60 this matters a lot because rendering dropped frames can starve the queue.

    func writerCanAcceptVideoFrame(_ writer: RecordingWriter) -> Bool {
        if !writer.hasStartedSession {
            return true
        }

        return writer.videoInput.isReadyForMoreMediaData
    }

    func handleRearVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        markCaptureReadyIfNeeded()

        if pendingRearPhotoCaptureCount > 0, let copiedBuffer = copyPixelBuffer(from: imageBuffer) {
            pendingRearPhotoCaptureCount -= 1
            saveRearPhoto(from: copiedBuffer, angle: rearCaptureAngle)
        }

        guard let recording = activeLoopRecording?.currentSegment else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        switch recording.mode {
        case .pipSingleFile:
            guard writerCanAcceptVideoFrame(recording.primaryWriter) else { return }
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
            guard writerCanAcceptVideoFrame(recording.primaryWriter) else { return }
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

    func handleFrontVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard multiCamSupported else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let needsFrontBufferForPiP = recordingMode == .pipSingleFile
        let shouldUpdateFrontBufferForPiP = needsFrontBufferForPiP && shouldUpdateFrontPiPBufferNow()
        let shouldRefreshFrontPreview = (!isRecording || recordingMode == .pipSingleFile) && shouldQueueFrontPreviewNow()

        // one copied front frame can feed the writer path and the small preview path
        if shouldUpdateFrontBufferForPiP || shouldRefreshFrontPreview {
            if let copied = copyPixelBuffer(from: imageBuffer) {
                if shouldUpdateFrontBufferForPiP {
                    latestFrontPixelBuffer = copied
                }

                if shouldRefreshFrontPreview {
                    queueFrontPreviewImage(from: copied, angle: frontCaptureAngle)
                }
            }
        }

        guard let recording = activeLoopRecording?.currentSegment else { return }
        guard recording.mode == .dualSeparateFiles, let frontWriter = recording.secondaryWriter else { return }
        guard writerCanAcceptVideoFrame(frontWriter) else { return }
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

    func handleAudioSample(_ sampleBuffer: CMSampleBuffer) {
        markAudioReadyIfNeeded()

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
