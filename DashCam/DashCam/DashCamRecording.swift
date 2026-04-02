//
//  DashCamRecording.swift
//  DashCam
//
//  Created by Muhanned Alkhafaji on 3/1/26.
//

import Foundation
import AVFoundation
import UIKit

// recording models and writer

// this file holds the low level recording objects

// the big controller should be able to say "start a segment" or "finish a segment"

// without also having to own every tiny writer detail inline

final class RecordingWriter {
    
    // file destination for this one output clip
    
    let url: URL
    
    // final canvas size that this writer expects every rendered frame to match
    
    let canvasSize: CGSize
    
    // avfoundation movie writer backing this output file
    
    let writer: AVAssetWriter
    
    // video input that receives the rendered pixel buffers
    
    let videoInput: AVAssetWriterInput
    
    // optional audio input used when mic capture is enabled
    
    let audioInput: AVAssetWriterInput?
    
    // adaptor that turns pixel buffers into movie frames for the writer
    
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    
    // track whether writing has actually started yet
    
    private(set) var hasStartedSession: Bool = false
    
    // track whether finish was already called so the writer does not get finished twice
    
    private(set) var hasFinished: Bool = false
    
    init(url: URL, canvasSize: CGSize, quality: DashVideoQuality, includeAudio: Bool) throws {
        self.url = url
        self.canvasSize = canvasSize
        self.writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        
        // pull width and height once so the dictionaries stay easier to read
        
        let width = Int(canvasSize.width)
        let height = Int(canvasSize.height)
        
        // video output settings for the encoded movie file
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: quality.bitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        
        // realtime video input because this is camera capture, not offline export
        
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        
        // pixel buffer requirements for frames fed into the writer
        
        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: sourceAttributes
        )
        
        // attach the video input or fail early if the writer cannot accept it
        
        guard writer.canAdd(videoInput) else {
            throw DashCamError.couldNotCreateWriter
        }
        writer.add(videoInput)
        
        // optional audio path for mic recording
        
        if includeAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: 128_000
            ]
            
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true
            
            if writer.canAdd(audioInput) {
                writer.add(audioInput)
                self.audioInput = audioInput
            } else {
                self.audioInput = nil
            }
        } else {
            audioInput = nil
        }
    }
    
    // used when the controller wants the saved movie file to carry a rotation transform
    
    func setVideoTransform(_ transform: CGAffineTransform) {
        videoInput.transform = transform
    }
    
    // append one video frame into the file
    
    // first frame starts the writer session automatically
    
    func appendVideo(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        if hasFinished { return }
        
        if !hasStartedSession {
            writer.startWriting()
            writer.startSession(atSourceTime: presentationTime)
            hasStartedSession = true
        }
        
        guard videoInput.isReadyForMoreMediaData else { return }
        adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
    }
    
    // append one audio sample into the file
    
    func appendAudio(sampleBuffer: CMSampleBuffer) {
        guard hasStartedSession else { return }
        guard !hasFinished else { return }
        guard let audioInput else { return }
        guard audioInput.isReadyForMoreMediaData else { return }
        
        audioInput.append(sampleBuffer)
    }
    
    // close the file cleanly
    
    // if nothing was ever written, remove the empty placeholder file instead
    
    func finish(completion: @escaping () -> Void) {
        guard !hasFinished else {
            completion()
            return
        }
        
        hasFinished = true
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        
        if hasStartedSession {
            writer.finishWriting {
                completion()
            }
        } else {
            try? FileManager.default.removeItem(at: url)
            completion()
        }
    }
}

final class ActiveLoopRecording {
    
    // folder that holds all clips for this running loop session
    
    let folderURL: URL
    
    // timestamp style id shared across all segments from one recording session
    
    let sessionID: String
    
    // frozen rear camera angle captured when the loop recording started
    
    let rearAngle: CGFloat
    
    // frozen front camera angle captured when the loop recording started
    
    let frontAngle: CGFloat
    
    // current segment number used in filenames
    
    var segmentIndex: Int = 0
    
    // active segment being written right now
    
    var currentSegment: ActiveRecording?
    
    // timer that triggers segment rollover at the chosen clip length
    
    var segmentTimer: DispatchSourceTimer?
    
    init(folderURL: URL, sessionID: String, rearAngle: CGFloat, frontAngle: CGFloat) {
        self.folderURL = folderURL
        self.sessionID = sessionID
        self.rearAngle = rearAngle
        self.frontAngle = frontAngle
    }
}

final class ActiveRecording {
    
    // whether this segment is one combo file or two separate files
    
    let mode: RecordingMode
    
    // primary output writer
    
    // for pip mode this is the combo file
    
    // for dual mode this is the rear file
    
    let primaryWriter: RecordingWriter
    
    // optional second writer used for the front file in dual mode
    
    let secondaryWriter: RecordingWriter?
    
    // rear camera angle frozen for this segment
    
    let rearAngle: CGFloat
    
    // front camera angle frozen for this segment
    
    let frontAngle: CGFloat
    
    // whether front should actually be composited into the pip output for this segment
    
    let includeFrontInPiP: Bool
    
    init(
        mode: RecordingMode,
        primaryWriter: RecordingWriter,
        secondaryWriter: RecordingWriter?,
        rearAngle: CGFloat,
        frontAngle: CGFloat,
        includeFrontInPiP: Bool
    ) {
        self.mode = mode
        self.primaryWriter = primaryWriter
        self.secondaryWriter = secondaryWriter
        self.rearAngle = rearAngle
        self.frontAngle = frontAngle
        self.includeFrontInPiP = includeFrontInPiP
    }
    
    // convenient way to iterate every writer belonging to this segment
    
    var writers: [RecordingWriter] {
        [primaryWriter, secondaryWriter].compactMap { $0 }
    }
}

enum DashCamError: LocalizedError {
    
    // camera hardware / session setup errors
    
    case noRearCamera
    case noFrontCamera
    case couldNotAddInput
    case couldNotAddVideoOutput
    case couldNotAddConnection
    case couldNotCreateWriter
    case couldNotCreateMultiCamSession
    
    var errorDescription: String? {
        switch self {
        case .noRearCamera:
            return "Could not find the rear camera."
        case .noFrontCamera:
            return "Could not find the front camera."
        case .couldNotAddInput:
            return "Could not attach one of the camera or audio inputs."
        case .couldNotAddVideoOutput:
            return "Could not attach one of the video outputs."
        case .couldNotAddConnection:
            return "Could not create one of the capture connections."
        case .couldNotCreateWriter:
            return "Could not create the file writer for recording."
        case .couldNotCreateMultiCamSession:
            return "Could not create a multi-camera capture session."
        }
    }
}
