import SwiftUI
import AVFoundation
import Photos
import UIKit
import Observation
import AudioToolbox

@Observable
final class CameraManager {
    let session = AVCaptureSession()

    var isAuthorized = false
    var message = "Checking camera permission..."
    var capturedImage: UIImage?
    var latestCapturedImage: UIImage?
    var latestSavedAssetIdentifier: String?
    var photoStatus = ""
    var zoomFactor: Double = 1.0
    var maxZoomFactor: Double = 40.0
    var flashEnabled = false
    var flashAvailable = false

    private var cameraDevice: AVCaptureDevice?
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private var isConfigured = false
    private var photoDelegate: PhotoCaptureDelegate?
    private var soundPlayer: AVAudioPlayer?

    // Keep only the latest pending zoom request.
    private let zoomLock = NSLock()
    private var pendingZoom: Double?
    private var zoomWorkerScheduled = false

    init() {
        checkCameraPermission()
    }

    // MARK: - Permission

    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
            configureSession()

        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isAuthorized = granted

                    if granted {
                        self.configureSession()
                    } else {
                        self.message = "Camera permission was denied."
                    }
                }
            }

        case .denied, .restricted:
            setMessage("Enable camera access in Settings.")

        @unknown default:
            setMessage("Unable to check camera permission.")
        }
    }

    // MARK: - Configure Camera

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self, !self.isConfigured else { return }

            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            guard let device = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .back
            ) else {
                self.session.commitConfiguration()
                self.setMessage("No rear camera is available.")
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)

                guard self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    self.setMessage("Unable to add camera input.")
                    return
                }

                self.session.addInput(input)

                guard self.session.canAddOutput(self.photoOutput) else {
                    self.session.commitConfiguration()
                    self.setMessage("Unable to add photo output.")
                    return
                }

                self.session.addOutput(self.photoOutput)
                self.cameraDevice = device
                self.isConfigured = true

                DispatchQueue.main.async {
                    self.maxZoomFactor = min(
                        Double(device.activeFormat.videoMaxZoomFactor),
                        40.0
                    )
                    self.zoomFactor = 1.0
                    self.flashAvailable = device.hasFlash
                }

                self.session.commitConfiguration()
                self.session.startRunning()
                self.setMessage("Camera ready. Long-press to focus.")
            } catch {
                self.session.commitConfiguration()
                self.setMessage(
                    "Camera setup failed: " + error.localizedDescription
                )
            }
        }
    }

    // MARK: - System Sounds

    func playSysSounds(soundID: UInt32) {
        AudioServicesPlaySystemSound(soundID)
    }

    func playZoomHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.prepare()
        generator.impactOccurred(intensity: 0.5)
    }    

    func playLightZoomHaptic() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    // MARK: - Bundled CAF Sounds

    func playSound(_ name: String) {
        let url =
            Bundle.main.url(
                forResource: name,
                withExtension: "caf",
                subdirectory: "Sounds"
            )
            ?? Bundle.main.url(forResource: name, withExtension: "caf")

        guard let url else {
            print("Sound file not found: \(name).caf")
            return
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, options: [.mixWithOthers])
            try audioSession.setActive(true)

            soundPlayer = try AVAudioPlayer(contentsOf: url)
            soundPlayer?.volume = 1.0
            soundPlayer?.prepareToPlay()
            soundPlayer?.play()
        } catch {
            print("Sound playback error: " + error.localizedDescription)
        }
    }

    // MARK: - Autofocus and Exposure

    func focus(at point: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self,
                  self.isConfigured,
                  let device = self.cameraDevice else { return }

            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                let focusPoint = CGPoint(
                    x: min(max(point.x, 0.0), 1.0),
                    y: min(max(point.y, 0.0), 1.0)
                )

                guard device.isFocusPointOfInterestSupported else {
                    self.setMessage("Camera does not support focus points.")
                    return
                }

                device.focusPointOfInterest = focusPoint

                if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                } else if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                } else {
                    self.setMessage("Autofocus is not supported.")
                    return
                }

                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = focusPoint

                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }

                self.setMessage(
                    String(
                        format: "[ %.2f, %.2f ]",
                        focusPoint.x * 100,
                        focusPoint.y * 100
                    )
                )

                DispatchQueue.main.async {
                    self.playSound("focus")
                }
            } catch {
                self.setMessage("Focus error: " + error.localizedDescription)
            }
        }
    }

    // MARK: - Camera Zoom

    func setZoom(_ factor: Double) {
        let requestedZoom = min(
            max(factor, 1.0),
            maxZoomFactor
        )

        DispatchQueue.main.async { [weak self] in
            self?.zoomFactor = requestedZoom
        }

        zoomLock.lock()
        pendingZoom = requestedZoom

        if zoomWorkerScheduled {
            zoomLock.unlock()
            return
        }

        zoomWorkerScheduled = true
        zoomLock.unlock()

        sessionQueue.async { [weak self] in
            guard let self else { return }

            while true {
                self.zoomLock.lock()

                let nextZoom = self.pendingZoom
                self.pendingZoom = nil

                guard let nextZoom else {
                    self.zoomWorkerScheduled = false
                    self.zoomLock.unlock()
                    break
                }

                self.zoomLock.unlock()

                guard self.isConfigured,
                      let device = self.cameraDevice else {
                    continue
                }

                do {
                    try device.lockForConfiguration()
                    let hardwareMaxZoom = Double(
                        device.activeFormat.videoMaxZoomFactor
                    )

                    let zoom = min(
                        max(nextZoom, 1.0),
                        min(hardwareMaxZoom, self.maxZoomFactor)
                    )

                    if abs(Double(device.videoZoomFactor) - zoom) > 0.01 {
                        device.videoZoomFactor = CGFloat(zoom)
                    }

                    device.unlockForConfiguration()
                } catch {
                    self.setMessage("Zoom error: " + error.localizedDescription)
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
        }
    }

    // MARK: - Flash

    func toggleFlash() {
        guard flashAvailable else {
            setMessage("Flash is not available.")
            return
        }

        flashEnabled.toggle()
    }

    // MARK: - Capture Photo

    func capturePhoto(
        previewScale: CGFloat = 1.0,
        previewOffset: CGSize = .zero,
        previewSize: CGSize = .zero
    ) {
        guard isAuthorized, isConfigured else {
            setMessage("Camera is not ready.")
            return
        }

        let settings = AVCapturePhotoSettings()

        if let device = cameraDevice,
           device.hasFlash,
           device.isFlashAvailable {
            settings.flashMode = flashEnabled ? .on : .off
        }

        let delegate = PhotoCaptureDelegate { [weak self] image in
            guard let self else { return }

            let framedImage = image.flatMap {
                self.cropImageToPreview(
                    $0,
                    scale: previewScale,
                    offset: previewOffset,
                    previewSize: previewSize
                )
            }

            DispatchQueue.main.async {
                if let framedImage {
                    self.latestCapturedImage = framedImage
                    self.latestSavedAssetIdentifier = nil
                    self.photoStatus = "Photo captured."
                    self.savePhoto(framedImage)
                } else {
                    self.photoStatus = "Unable to capture photo."
                }
            }

            self.photoDelegate = nil
        }

        photoDelegate = delegate
        photoOutput.capturePhoto(with: settings, delegate: delegate)

        DispatchQueue.main.async {
            self.playSound("shutter")
        }
    }

    private func cropImageToPreview(
        _ image: UIImage,
        scale: CGFloat,
        offset: CGSize,
        previewSize: CGSize
    ) -> UIImage? {
        guard previewSize.width > 0,
              previewSize.height > 0,
              image.cgImage != nil else {
            return image
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true

        let normalizedImage = UIGraphicsImageRenderer(
            size: image.size,
            format: format
        ).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }

        guard let normalizedCGImage = normalizedImage.cgImage else {
            return image
        }

        let imageWidth = CGFloat(normalizedCGImage.width)
        let imageHeight = CGFloat(normalizedCGImage.height)
        let previewAspect = previewSize.width / previewSize.height
        let imageAspect = imageWidth / imageHeight

        var baseRect = CGRect(
            x: 0,
            y: 0,
            width: imageWidth,
            height: imageHeight
        )

        if imageAspect > previewAspect {
            baseRect.size.width = imageHeight * previewAspect
            baseRect.origin.x = (imageWidth - baseRect.width) / 2
        } else if imageAspect < previewAspect {
            baseRect.size.height = imageWidth / previewAspect
            baseRect.origin.y = (imageHeight - baseRect.height) / 2
        }

        let safeScale = min(max(scale, 1.0), 4.0)
        let cropWidth = baseRect.width / safeScale
        let cropHeight = baseRect.height / safeScale

        let offsetXFraction = offset.width / (safeScale * previewSize.width)
        let offsetYFraction = offset.height / (safeScale * previewSize.height)

        var cropRect = CGRect(
            x: baseRect.minX + baseRect.width * (0.5 - 0.5 / safeScale - offsetXFraction),
            y: baseRect.minY + baseRect.height * (0.5 - 0.5 / safeScale - offsetYFraction),
            width: cropWidth,
            height: cropHeight
        )

        cropRect.origin.x = min(
            max(cropRect.origin.x, baseRect.minX),
            baseRect.maxX - cropRect.width
        )
        cropRect.origin.y = min(
            max(cropRect.origin.y, baseRect.minY),
            baseRect.maxY - cropRect.height
        )

        let pixelRect = CGRect(
            x: floor(cropRect.origin.x),
            y: floor(cropRect.origin.y),
            width: floor(cropRect.width),
            height: floor(cropRect.height)
        ).integral

        guard let croppedCGImage = normalizedCGImage.cropping(to: pixelRect) else {
            return image
        }

        return UIImage(
            cgImage: croppedCGImage,
            scale: normalizedImage.scale,
            orientation: .up
        )
    }

    // MARK: - Save Photo

    private func savePhoto(_ image: UIImage) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)

        if status == .authorized || status == .limited {
            writePhoto(image)
        } else if status == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] newStatus in
                guard let self else { return }

                DispatchQueue.main.async {
                    if newStatus == .authorized || newStatus == .limited {
                        self.writePhoto(image)
                    } else {
                        self.photoStatus = "Photo captured, but saving permission was denied."
                    }
                }
            }
        } else {
            DispatchQueue.main.async {
                self.photoStatus = "Photo captured, but Photos access is disabled."
            }
        }
    }

    private func writePhoto(_ image: UIImage) {
        var placeholder: PHObjectPlaceholder?

        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetChangeRequest.creationRequestForAsset(
                from: image
            )

            placeholder = request.placeholderForCreatedAsset
        }) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }

                if success, let identifier = placeholder?.localIdentifier {
                    self.latestSavedAssetIdentifier = identifier
                    self.photoStatus = "Photo saved to Photos."
                } else {
                    self.photoStatus =
                        "Save failed: " +
                        (error?.localizedDescription ?? "Unknown error")
                }
            }
        }
    }

    // MARK: - Review Controls

    func reviewLatestPhoto() {
        guard let latestCapturedImage else { return }
        capturedImage = latestCapturedImage
    }

    func closePhotoReview() {
        capturedImage = nil
    }

    // MARK: - Status Message

    private func setMessage(_ text: String) {
        DispatchQueue.main.async {
            self.message = text
        }
    }
}

// MARK: - Photo Capture Delegate

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (UIImage?) -> Void

    init(completion: @escaping (UIImage?) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            completion(nil)
            return
        }

        completion(image)
    }
}

// MARK: - Camera Preview

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let focusScale: CGFloat
    let onLongPress: (CGPoint) -> Void

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onLongPress = onLongPress
        view.focusScale = focusScale

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )

        longPress.minimumPressDuration = 0.6
        longPress.cancelsTouchesInView = false
        longPress.delaysTouchesBegan = false
        longPress.delaysTouchesEnded = false
        view.addGestureRecognizer(longPress)

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )

        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        doubleTap.delaysTouchesBegan = false
        view.addGestureRecognizer(doubleTap)

        doubleTap.require(toFail: longPress)

        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }

        uiView.onLongPress = onLongPress
        uiView.focusScale = focusScale
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject {
        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began,
                  let view = recognizer.view as? CameraPreviewView else {
                return
            }

            let location = recognizer.location(in: view)
            let cameraPoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: location)

            view.showFocusSquare(at: location)
            view.onLongPress?(cameraPoint)
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let view = recognizer.view as? CameraPreviewView else {
                return
            }

            let location = recognizer.location(in: view)
            let cameraPoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: location)

            view.showFocusSquare(at: location)
            view.onLongPress?(cameraPoint)
        }
    }
}

// MARK: - Preview View and Focus Overlay

final class CameraPreviewView: UIView {
    var onLongPress: ((CGPoint) -> Void)?
    var focusScale: CGFloat = 1.0

    private let focusOverlay = UIView()
    private let focusSquare = CAShapeLayer()

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupFocusOverlay()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupFocusOverlay()
    }

    private func setupFocusOverlay() {
        focusOverlay.backgroundColor = .clear
        focusOverlay.isUserInteractionEnabled = false
        focusOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(focusOverlay)

        NSLayoutConstraint.activate([
            focusOverlay.topAnchor.constraint(equalTo: topAnchor),
            focusOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            focusOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            focusOverlay.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        focusSquare.fillColor = UIColor.clear.cgColor
        focusSquare.strokeColor = UIColor.systemYellow.cgColor
        focusSquare.lineWidth = 1.0
        focusSquare.opacity = 0
        focusSquare.actions = [
            "opacity": NSNull(),
            "path": NSNull(),
            "position": NSNull()
        ]

        focusOverlay.layer.addSublayer(focusSquare)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        focusSquare.frame = focusOverlay.bounds
    }

    func showFocusSquare(at point: CGPoint) {
        let scale = max(focusScale, 1.0)
        let squareSize: CGFloat = 16.0 / scale
        let halfSize = squareSize / 2.0

        focusSquare.lineWidth = 2.0 / scale

        let bounds = focusOverlay.bounds
        guard bounds.width >= squareSize,
              bounds.height >= squareSize else { return }

        let x = min(max(point.x, halfSize), bounds.width - halfSize)
        let y = min(max(point.y, halfSize), bounds.height - halfSize)

        let rect = CGRect(
            x: x - halfSize,
            y: y - halfSize,
            width: squareSize,
            height: squareSize
        )

        focusSquare.path = UIBezierPath(rect: rect).cgPath
        focusSquare.removeAllAnimations()
        focusSquare.opacity = 1

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + 1.2
        fade.duration = 0.5
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false

        focusSquare.add(fade, forKey: "focusFade")
    }
}
