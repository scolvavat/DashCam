import AVFoundation
import UIKit
import CoreImage

extension DashCamController {

    // front preview image

    // this path only builds the small front thumbnail
    // the real rear preview still lives in the preview layer wrapper

    var frontPreviewMinimumInterval: CFTimeInterval {
        if isRecording && frameRate == .fps60 {
            return 0.12
        }

        return isRecording ? 0.08 : 0.06
    }

    var currentFrontPreviewTargetSize: CGSize {
        if isRecording && frameRate == .fps60 {
            return frontPreviewTargetSizeAt60FPS
        }

        return frontPreviewTargetSize
    }

    func shouldQueueFrontPreviewNow() -> Bool {
        guard showFrontPreview else { return false }
        guard !isFrontPreviewRenderInFlight else { return false }

        let now = CACurrentMediaTime()
        return now - lastFrontPreviewPush > frontPreviewMinimumInterval
    }

    func queueFrontPreviewImage(from pixelBuffer: CVPixelBuffer, angle: CGFloat) {
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

    func makeUIImage(
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

    func copyPixelBuffer(from pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
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

    func makeWriterPixelBuffer(for writer: RecordingWriter) -> CVPixelBuffer? {
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

    func fastPathCanUseSourceBuffer(_ pixelBuffer: CVPixelBuffer, for writer: RecordingWriter) -> Bool {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        return width == Int(writer.canvasSize.width) && height == Int(writer.canvasSize.height) && !burnStamp
    }

    // render helpers

    // every writer path ends up here when it needs rotation, burn in text, or pip compositing

    func renderedPixelBuffer(
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
        let sourceFill = aspectFillCIImage(sourceImage, into: canvasRect)
        composedImage = sourceFill.composited(over: composedImage)

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
            if let borderOverlay = pipBorderOverlayImage(for: pipRect, canvasSize: writer.canvasSize) {
                composedImage = borderOverlay.composited(over: composedImage)
            }
        }

        if burnStamp, let stampOverlay = stampOverlayImage(for: writer.canvasSize) {
            composedImage = stampOverlay.composited(over: composedImage)
        }

        ciContext.render(composedImage, to: outputBuffer, bounds: canvasRect, colorSpace: colorSpace)

        return outputBuffer
    }

    func aspectFillCIImage(_ image: CIImage, into rect: CGRect) -> CIImage {
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

    func applyHorizontalMirror(to image: CIImage) -> CIImage {
        let extent = image.extent.integral
        return image.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -extent.width, y: 0))
    }

    func applyDiscreteRotation(angle: CGFloat, to image: CIImage) -> CIImage {
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

    func normalizedRightAngle(_ angle: CGFloat) -> Int {
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

    func transformForRotationAngle(_ angle: CGFloat, canvasSize: CGSize) -> CGAffineTransform {
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

    func normalizedAngle(_ angle: CGFloat) -> CGFloat {
        let remainder = angle.truncatingRemainder(dividingBy: 360)
        return remainder >= 0 ? remainder : remainder + 360
    }

    // stamp overlay

    // the burn in text changes slowly, so cache the image and reuse it across frames

    func stampOverlayImage(for canvasSize: CGSize) -> CIImage? {
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

            let font = UIFont.monospacedSystemFont(
                ofSize: max(14, min(canvasSize.width * 0.018, 28)),
                weight: .semibold
            )
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

    // snapshots

    func saveRearPhoto(from pixelBuffer: CVPixelBuffer, angle: CGFloat) {
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

    func pipBorderOverlayImage(for pipRect: CGRect, canvasSize: CGSize) -> CIImage? {
        let key = [
            Int(canvasSize.width),
            Int(canvasSize.height),
            Int(pipRect.origin.x),
            Int(pipRect.origin.y),
            Int(pipRect.width),
            Int(pipRect.height)
        ].map(String.init).joined(separator: "|")

        if cachedPiPBorderKey == key {
            return cachedPiPBorderOverlay
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        let image = renderer.image { _ in
            let path = UIBezierPath(rect: pipRect)
            UIColor.white.withAlphaComponent(0.72).setStroke()
            path.lineWidth = 3
            path.stroke()
        }

        let overlay = CIImage(image: image)
        cachedPiPBorderKey = key
        cachedPiPBorderOverlay = overlay
        return overlay
    }
}
