import SwiftUI
import AVFoundation
import Photos
import UIKit

private struct LibraryPhotoSelection: Identifiable {
    let id = UUID()
    let asset: PHAsset?
    let fallbackImage: UIImage?
}

// MARK: - Main Camera View

struct AppView: View {
    @State private var camera = CameraManager()
    @State private var controls = CentralManager()

    // Shared with PhotoManagementView.
    @StateObject private var photoManager = PhotoManager.shared

    @State private var previewScale: CGFloat = 1.0
    @State private var previewOffset: CGSize = .zero
    @State private var gestureStartScale: CGFloat = 1.0
    @State private var gestureStartOffset: CGSize = .zero
    @State private var previewSize: CGSize = .zero

    @State private var showZoomSlider = false
    @State private var sliderZoom: Double = 1.0
    @State private var wheelActivityID = 0
    @State private var lastHapticZoomStep: Int? = nil

    @State private var customZoom: Double = 1.0
    @State private var hasCustomZoom = false

    @State private var toastMessage: String?

    @State private var latestLibraryAsset: PHAsset?
    @State private var latestLibraryThumbnail: UIImage?
    @State private var selectedLibraryPhoto: LibraryPhotoSelection?

    @State private var showPhotoManagement = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            cameraScreen
        }
        .preferredColorScheme(.dark)
        .sheet(
            item: $selectedLibraryPhoto,
            onDismiss: {
                refreshLatestLibraryPhotoAfterDetail()
            }
        ) { selection in
            PhotoDetailView(
                asset: selection.asset,
                fallbackImage: selection.fallbackImage,
                manager: photoManager
            )
            .id(selection.id)
        }
        .fullScreenCover(isPresented: $showPhotoManagement) {
            PhotoManagementView()
        }
        .onChange(of: camera.photoStatus) { _, newValue in
            guard !newValue.isEmpty else { return }

            if newValue == "Photo captured.",
               let image = camera.latestCapturedImage {
                latestLibraryThumbnail = image
            }

            if newValue == "Photo saved to Photos." {
                latestLibraryThumbnail = camera.latestCapturedImage
                loadLatestLibraryPhoto()
            }

            showToast(newValue)
        }
        .onChange(of: camera.zoomFactor) { _, newValue in
            if abs(sliderZoom - newValue) > 0.02 {
                sliderZoom = newValue
            }
        }
        .task {
            loadLatestLibraryPhoto()
        }
        .task(id: toastMessage) {
            guard toastMessage != nil else { return }

            do {
                try await Task.sleep(for: .seconds(2.2))
            } catch {
                return
            }

            withAnimation(.easeOut(duration: 0.2)) {
                toastMessage = nil
            }
        }
        .overlay(alignment: .top) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .overlay {
                        Capsule()
                            .stroke(
                                .white.opacity(0.2),
                                lineWidth: 1
                            )
                    }
                    .padding(.top, 12)
                    .transition(
                        .move(edge: .top)
                            .combined(with: .opacity)
                    )
                    .zIndex(20)
            }
        }
    }

    // MARK: - Latest Photo from Library

    private func loadLatestLibraryPhoto() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)

        if status == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) {
                newStatus in

                DispatchQueue.main.async {
                    if newStatus == .authorized || newStatus == .limited {
                        fetchLatestLibraryPhoto()
                    } else {
                        latestLibraryAsset = nil
                        latestLibraryThumbnail = camera.latestCapturedImage
                    }
                }
            }
            return
        }

        guard status == .authorized || status == .limited else {
            latestLibraryAsset = nil
            latestLibraryThumbnail = camera.latestCapturedImage
            return
        }

        fetchLatestLibraryPhoto()
    }

    private func fetchLatestLibraryPhoto() {
        let options = PHFetchOptions()
        options.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: false)
        ]
        options.fetchLimit = 1

        let results = PHAsset.fetchAssets(
            with: .image,
            options: options
        )

        guard let asset = results.firstObject else {
            DispatchQueue.main.async {
                latestLibraryAsset = nil

                if let latestImage = camera.latestCapturedImage {
                    latestLibraryThumbnail = latestImage
                } else {
                    latestLibraryThumbnail = nil
                }
            }
            return
        }

        DispatchQueue.main.async {
            latestLibraryAsset = asset
        }

        let imageOptions = PHImageRequestOptions()
        imageOptions.deliveryMode = .highQualityFormat
        imageOptions.resizeMode = .fast
        imageOptions.isNetworkAccessAllowed = true
        imageOptions.isSynchronous = false

        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 240, height: 240),
            contentMode: .aspectFill,
            options: imageOptions
        ) { image, info in
            if let cancelled = info?[PHImageCancelledKey] as? Bool,
               cancelled {
                return
            }

            guard let image else { return }

            DispatchQueue.main.async {
                if camera.latestCapturedImage == nil {
                    latestLibraryThumbnail = image
                }
            }
        }
    }

    // MARK: - Open Latest Photo

    private func openLatestPhoto() {
        if let identifier = camera.latestSavedAssetIdentifier {
            photoManager.fetchAsset(identifier: identifier) { asset in
                guard let asset else {
                    showToast(
                        photoManager.errorMessage
                            ?? "Could not find this photo in Photos."
                    )
                    return
                }

                selectedLibraryPhoto = LibraryPhotoSelection(
                    asset: asset,
                    fallbackImage: camera.latestCapturedImage
                        ?? latestLibraryThumbnail
                )
            }
            return
        }

        if camera.latestCapturedImage != nil {
            showToast(
                "The photo is still being saved. Please try again shortly."
            )
            return
        }

        if let asset = latestLibraryAsset {
            selectedLibraryPhoto = LibraryPhotoSelection(
                asset: asset,
                fallbackImage: latestLibraryThumbnail
            )
        } else if let image = latestLibraryThumbnail {
            selectedLibraryPhoto = LibraryPhotoSelection(
                asset: nil,
                fallbackImage: image
            )
        } else {
            loadLatestLibraryPhoto()
            showToast("Loading your latest photo…")
        }
    }

    // MARK: - Refresh After Photo Detail Closes

    private func refreshLatestLibraryPhotoAfterDetail() {
        camera.latestCapturedImage = nil
        camera.latestSavedAssetIdentifier = nil

        latestLibraryAsset = nil
        latestLibraryThumbnail = nil

        loadLatestLibraryPhoto()
    }

    // MARK: - Camera Screen

    private var cameraScreen: some View {
        VStack(spacing: 0) {
            topBar

            GeometryReader { geometry in
                ZStack {
                    // Live camera preview.
                    CameraPreview(
                        session: camera.session,
                        focusScale: previewScale
                    ) { point in
                        camera.focus(at: point)
                    }
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height
                    )
                    .scaleEffect(previewScale)
                    .offset(previewOffset)
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height
                    )
                    .clipped()
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        previewGesture(in: geometry.size)
                    )
                    .simultaneousGesture(
                        TapGesture()
                            .onEnded {
                                hideZoomWheel()
                            }
                    )

                    // Grid remains fixed to the screen.
                    if controls.showGrid {
                        CameraGridOverlay()
                            .frame(
                                width: geometry.size.width,
                                height: geometry.size.height
                            )
                            .clipped()
                            .allowsHitTesting(false)
                            .zIndex(1)
                    }

                    // Reusable horizon indicator from CentralManager.swift.
                    if controls.showLevel {
                        CameraHorizonLevelIndicator(
                            angle: controls.levelAngle,
                            isLevel: controls.isLevel,
                            isAvailable: controls.isMotionAvailable,
                            lineLength: 100,
                            lineThickness: 1.5
                        )
                        .frame(
                            width: geometry.size.width,
                            height: geometry.size.height
                        )
                        .allowsHitTesting(false)
                        .zIndex(2)
                    }

                    // Standard zoom buttons.
                    if !showZoomSlider {
                        VStack {
                            Spacer()

                            HStack {
                                Spacer()

                                HStack(spacing: 10) {
                                    zoomButton(1.0)
                                    zoomButton(2.0)
                                    zoomButton(4.0)
                                    zoomButton(8.0)

                                    if hasCustomZoom {
                                        customZoomButton
                                    }
                                }
                            }
                            .padding(.trailing, 12)
                            .padding(.bottom, 16)
                        }
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity
                        )
                        .zIndex(5)
                    }

                    // Circular zoom wheel.
                    if showZoomSlider {
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity
                            )
                            .onTapGesture {
                                hideZoomWheel()
                            }
                            .overlay(alignment: .bottomTrailing) {
                                CircularZoomWheel(
                                    zoom: sliderZoom,
                                    maxZoom: camera.maxZoomFactor
                                ) { newZoom in
                                    let zoomStep = Int(
                                        (newZoom * 10).rounded()
                                    )

                                    if lastHapticZoomStep != zoomStep {
                                        if lastHapticZoomStep != nil {
                                            camera.playLightZoomHaptic()
                                        }

                                        lastHapticZoomStep = zoomStep
                                    }

                                    sliderZoom = newZoom
                                    camera.setZoom(newZoom)

                                    customZoom = newZoom
                                    hasCustomZoom = true

                                    wheelActivityID += 1
                                }
                                .frame(width: 360, height: 360)
                                .task(id: wheelActivityID) {
                                    do {
                                        try await Task.sleep(
                                            for: .seconds(3)
                                        )
                                    } catch {
                                        return
                                    }

                                    guard !Task.isCancelled else {
                                        return
                                    }

                                    withAnimation(
                                        .easeInOut(duration: 0.2)
                                    ) {
                                        showZoomSlider = false
                                    }
                                }
                            }
                            .transition(.opacity)
                            .zIndex(10)
                    }
                }
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height
                )
                .clipped()
                .onAppear {
                    previewSize = geometry.size
                }
                .onChange(of: geometry.size) { _, newSize in
                    previewSize = newSize
                }
            }

            bottomControls
        }
        .background(Color.black)
        .onAppear {
            sliderZoom = camera.zoomFactor
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Text("My Camera")
                .font(.headline)

            Spacer()

            Text(camera.message)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.tail)

            // Grid toggle.
            Button {
                controls.toggleGrid()
            } label: {
                Image(systemName: "square.grid.3x3")
                    .font(.title3)
                    .foregroundStyle(
                        controls.showGrid ? .yellow : .white
                    )
            }
            .accessibilityLabel(
                controls.showGrid ? "Hide grid lines" : "Show grid lines"
            )

            // Horizon-level toggle.
            Button {
                controls.toggleLevel()
            } label: {
                Image(systemName: "level")
                    .font(.title3)
                    .foregroundStyle(
                        controls.showLevel ? .yellow : .white
                    )
            }
            .accessibilityLabel(
                controls.showLevel
                    ? "Hide horizon level"
                    : "Show horizon level"
            )
            .accessibilityHint(
                "Displays a guide to help keep the camera level."
            )

            Button {
                showPhotoManagement = true
            } label: {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.title3)
            }
            .accessibilityLabel("Manage photos")

            Button {
                resetPreview()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.title3)
            }
            .accessibilityLabel("Reset preview zoom and position")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    // MARK: - Standard Zoom Buttons

    private func zoomButton(_ value: Double) -> some View {
        let isSelected = abs(camera.zoomFactor - value) < 0.15

        return Text(
            isSelected ? "\(Int(value))×" : "\(Int(value))"
        )
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(isSelected ? .black : .white)
        .frame(width: 44, height: 38)
        .background(
            isSelected ? Color.yellow : Color.black.opacity(0.55)
        )
        .clipShape(Capsule())
        .contentShape(Capsule())
        .gesture(
            LongPressGesture(minimumDuration: 0.45)
                .exclusively(before: TapGesture())
                .onEnded { result in
                    switch result {
                    case .first(true):
                        sliderZoom = value
                        camera.setZoom(value)
                        wheelActivityID += 1

                        withAnimation(.easeInOut(duration: 0.2)) {
                            showZoomSlider = true
                        }

                    case .second(_):
                        sliderZoom = value
                        camera.setZoom(value)

                        withAnimation(.easeInOut(duration: 0.2)) {
                            showZoomSlider = false
                        }

                    default:
                        break
                    }
                }
        )
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(Int(value)) times camera zoom")
        .accessibilityHint(
            "Tap to select zoom. Long-press to open the zoom wheel."
        )
    }

    // MARK: - Custom Zoom Memory Button

    private var customZoomButton: some View {
        let isSelected = abs(camera.zoomFactor - customZoom) < 0.15

        return Button {
            sliderZoom = customZoom
            camera.setZoom(customZoom)

            withAnimation(.easeInOut(duration: 0.2)) {
                showZoomSlider = false
            }
        } label: {
            Text(
                String(
                    format: abs(customZoom.rounded() - customZoom) < 0.05
                        ? "%.0f×"
                        : "%.1f×",
                    customZoom
                )
            )
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(isSelected ? .black : .white)
            .frame(minWidth: 38)
            .frame(height: 34)
            .padding(.horizontal, 3)
            .background(
                isSelected ? Color.yellow : Color.black.opacity(0.55)
            )
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Custom zoom \(String(format: "%.1f", customZoom)) times"
        )
        .accessibilityHint(
            "Restore the zoom value saved from the zoom wheel."
        )
    }

    // MARK: - Show / Hide Zoom Wheel

    private func hideZoomWheel() {
        guard showZoomSlider else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            showZoomSlider = false
        }
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        HStack {
            Button {
                openLatestPhoto()
            } label: {
                Group {
                    if let image = camera.latestCapturedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else if let image = latestLibraryThumbnail {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "photo")
                            .font(.title2)
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.white.opacity(0.6), lineWidth: 1)
                }
            }
            .accessibilityLabel("Preview latest photo")

            Spacer()

            Button {
                camera.capturePhoto(
                    previewScale: previewScale,
                    previewOffset: previewOffset,
                    previewSize: previewSize
                )
            } label: {
                Circle()
                    .fill(.white)
                    .frame(width: 72, height: 72)
                    .overlay {
                        Circle()
                            .stroke(.gray, lineWidth: 3)
                            .padding(5)
                    }
            }
            .accessibilityLabel("Take photo")

            Spacer()

            Button {
                camera.toggleFlash()
            } label: {
                Image(
                    systemName: camera.flashEnabled
                        ? "bolt.fill"
                        : "bolt.slash"
                )
                .font(.title2)
                .foregroundStyle(
                    camera.flashEnabled ? .yellow : .white
                )
                .frame(width: 48, height: 48)
            }
            .accessibilityLabel("Toggle flash")
        }
        .padding(.horizontal, 26)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .foregroundStyle(.white)
    }

    // MARK: - Preview Gestures

    private func previewGesture(in size: CGSize) -> some Gesture {
        SimultaneousGesture(
            DragGesture(
                minimumDistance: 1,
                coordinateSpace: .local
            )
            .onChanged { value in
                let maxX = max(
                    0,
                    size.width * (previewScale - 1) / 2
                )
                let maxY = max(
                    0,
                    size.height * (previewScale - 1) / 2
                )

                let proposedX = gestureStartOffset.width
                    + value.translation.width
                let proposedY = gestureStartOffset.height
                    + value.translation.height

                let newOffset = CGSize(
                    width: min(max(proposedX, -maxX), maxX),
                    height: min(max(proposedY, -maxY), maxY)
                )

                guard newOffset != previewOffset else { return }

                var transaction = Transaction()
                transaction.animation = nil

                withTransaction(transaction) {
                    previewOffset = newOffset
                }
            }
            .onEnded { _ in
                gestureStartOffset = previewOffset
            },

            MagnificationGesture()
                .onChanged { value in
                    let newScale = min(
                        max(gestureStartScale * value, 1.0),
                        4.0
                    )

                    var transaction = Transaction()
                    transaction.animation = nil

                    withTransaction(transaction) {
                        previewScale = newScale

                        let maxX = max(
                            0,
                            size.width * (newScale - 1) / 2
                        )
                        let maxY = max(
                            0,
                            size.height * (newScale - 1) / 2
                        )

                        previewOffset = CGSize(
                            width: min(
                                max(previewOffset.width, -maxX),
                                maxX
                            ),
                            height: min(
                                max(previewOffset.height, -maxY),
                                maxY
                            )
                        )
                    }
                }
                .onEnded { _ in
                    gestureStartScale = previewScale
                    gestureStartOffset = previewOffset
                }
        )
    }

    // MARK: - Reset Preview

    private func resetPreview() {
        withAnimation(.easeOut(duration: 0.2)) {
            previewScale = 1.0
            previewOffset = .zero
            gestureStartScale = 1.0
            gestureStartOffset = .zero
        }
    }

    // MARK: - Toast Message

    private func showToast(_ message: String) {
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
    }
}

#Preview {
    AppView()
}
