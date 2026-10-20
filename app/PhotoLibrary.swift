
import SwiftUI
import Photos
import UIKit
import Combine

// MARK: - Photo Manager

@MainActor
final class PhotoManager: ObservableObject {

    static let shared = PhotoManager()

    @Published private(set) var assets: [PHAsset] = []
    @Published var selectedIdentifiers: Set<String> = []
    @Published private(set) var authorizationStatus: PHAuthorizationStatus =
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var isLoading = false
    @Published var isDeleting = false
    @Published var errorMessage: String?

    var selectedCount: Int {
        selectedIdentifiers.count
    }

    var hasPhotoAccess: Bool {
        authorizationStatus == .authorized ||
        authorizationStatus == .limited
    }

    // MARK: - Photo Access

    func requestAccessAndFetch() {
        authorizationStatus =
            PHPhotoLibrary.authorizationStatus(for: .readWrite)

        if hasPhotoAccess {
            fetchAssets()
            return
        }

        guard authorizationStatus == .notDetermined else {
            errorMessage =
                "Photo library access is not available. Check Settings > Apps > MyFirstApp > Photos."
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .readWrite) {
            [weak self] status in

            Task { @MainActor in
                guard let self else { return }

                self.authorizationStatus = status

                if self.hasPhotoAccess {
                    self.fetchAssets()
                } else {
                    self.errorMessage =
                        "Photo library access was not granted."
                }
            }
        }
    }

    // MARK: - Refresh Photos

    func refresh() {
        authorizationStatus =
            PHPhotoLibrary.authorizationStatus(for: .readWrite)

        guard hasPhotoAccess else {
            assets = []
            selectedIdentifiers.removeAll()
            return
        }

        fetchAssets()
    }

    private func fetchAssets() {
        guard hasPhotoAccess else { return }

        isLoading = true

        let options = PHFetchOptions()
        options.sortDescriptors = [
            NSSortDescriptor(
                key: "creationDate",
                ascending: false
            )
        ]

        let result = PHAsset.fetchAssets(
            with: .image,
            options: options
        )

        var fetchedAssets: [PHAsset] = []
        fetchedAssets.reserveCapacity(result.count)

        result.enumerateObjects { asset, _, _ in
            fetchedAssets.append(asset)
        }

        assets = fetchedAssets

        let availableIDs = Set(
            fetchedAssets.map(\.localIdentifier)
        )

        selectedIdentifiers.formIntersection(availableIDs)
        isLoading = false
    }

    // MARK: - Find a Saved Photo

    func fetchAsset(
        identifier: String,
        completion: @escaping (PHAsset?) -> Void
    ) {
        authorizationStatus =
            PHPhotoLibrary.authorizationStatus(for: .readWrite)

        guard hasPhotoAccess else {
            errorMessage =
                "Photo library access is required. Check Settings > Apps > MyFirstApp > Photos."
            completion(nil)
            return
        }

        let result = PHAsset.fetchAssets(
            withLocalIdentifiers: [identifier],
            options: nil
        )

        guard let asset = result.firstObject else {
            errorMessage =
                "Could not find this photo in the Photos library. Check your Photos access permissions."
            completion(nil)
            return
        }

        errorMessage = nil
        completion(asset)
    }

    // MARK: - Selection

    func isSelected(_ asset: PHAsset) -> Bool {
        selectedIdentifiers.contains(asset.localIdentifier)
    }

    func toggleSelection(_ asset: PHAsset) {
        let identifier = asset.localIdentifier

        if selectedIdentifiers.contains(identifier) {
            selectedIdentifiers.remove(identifier)
        } else {
            selectedIdentifiers.insert(identifier)
        }
    }

    func selectAll() {
        selectedIdentifiers = Set(
            assets.map(\.localIdentifier)
        )
    }

    func deselectAll() {
        selectedIdentifiers.removeAll()
    }

    // MARK: - Delete Selected Photos

    func deleteSelected(
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        let identifiers = selectedIdentifiers

        guard !identifiers.isEmpty else {
            errorMessage = "No photos are selected."
            completion(false)
            return
        }

        let photosToDelete = assets.filter {
            identifiers.contains($0.localIdentifier)
        }

        deletePhotos(photosToDelete, completion: completion)
    }

    // MARK: - Delete One Photo

    func delete(
        asset: PHAsset,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        deletePhotos([asset], completion: completion)
    }

    // MARK: - Perform Deletion

    private func deletePhotos(
        _ photos: [PHAsset],
        completion: @escaping (Bool) -> Void
    ) {
        guard !photos.isEmpty else {
            errorMessage =
                "The photo to delete could not be found."
            completion(false)
            return
        }

        authorizationStatus =
            PHPhotoLibrary.authorizationStatus(for: .readWrite)

        guard hasPhotoAccess else {
            errorMessage =
                "Photo library access is required. Check your iPhone Photos permissions."
            completion(false)
            return
        }

        guard !isDeleting else {
            errorMessage =
                "A photo deletion is already in progress."
            completion(false)
            return
        }

        isDeleting = true
        errorMessage = nil

        let identifiersToDelete = Set(
            photos.map(\.localIdentifier)
        )

        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(
                photos as NSArray
            )
        }) { [weak self] success, error in

            Task { @MainActor in
                guard let self else {
                    completion(false)
                    return
                }

                self.isDeleting = false

                if success {
                    self.selectedIdentifiers.subtract(
                        identifiersToDelete
                    )

                    self.errorMessage = nil
                    self.fetchAssets()
                } else {
                    self.errorMessage =
                        error?.localizedDescription
                        ?? "iOS did not allow the selected photo(s) to be deleted."

                    print(
                        "Photo deletion failed: \(self.errorMessage ?? "Unknown error")"
                    )
                }

                completion(success)
            }
        }
    }
}

// MARK: - Selected Photo

private struct SelectedPhoto: Identifiable {
    let asset: PHAsset

    var id: String {
        asset.localIdentifier
    }
}

// MARK: - Photo Management View

struct PhotoManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = PhotoManager.shared

    @State private var isSelecting = false
    @State private var selectedPhoto: SelectedPhoto?
    @State private var showDeleteConfirmation = false
    @State private var showDeleteError = false

    private let columns = [
        GridItem(.flexible(), spacing: 3),
        GridItem(.flexible(), spacing: 3),
        GridItem(.flexible(), spacing: 3)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if !manager.hasPhotoAccess {
                    permissionView
                } else if manager.isLoading {
                    ProgressView("Loading photos…")
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity
                        )
                } else if manager.assets.isEmpty {
                    ContentUnavailableView(
                        "No Photos",
                        systemImage: "photo",
                        description: Text(
                            "No photos were found in your photo library."
                        )
                    )
                } else {
                    photoGrid
                }
            }
            .background(Color.black)
            .navigationTitle(
                isSelecting
                    ? "\(manager.selectedCount) Selected"
                    : "Photos"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if manager.hasPhotoAccess &&
                        !manager.assets.isEmpty {
                        Button(isSelecting ? "Cancel" : "Select") {
                            isSelecting.toggle()

                            if !isSelecting {
                                manager.deselectAll()
                            }
                        }
                    }
                }

                ToolbarItemGroup(placement: .bottomBar) {
                    if isSelecting {
                        Button("Select All") {
                            manager.selectAll()
                        }

                        Spacer()

                        Button("Deselect All") {
                            manager.deselectAll()
                        }

                        Spacer()

                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            if manager.isDeleting {
                                ProgressView()
                            } else {
                                Label(
                                    "Delete (\(manager.selectedCount))",
                                    systemImage: "trash"
                                )
                            }
                        }
                        .disabled(
                            manager.selectedCount == 0 ||
                            manager.isDeleting
                        )
                    } else {
                        Button {
                            manager.refresh()
                        } label: {
                            Label(
                                "Refresh",
                                systemImage: "arrow.clockwise"
                            )
                        }

                        Spacer()

                        Text("\(manager.assets.count) photos")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.visible, for: .bottomBar)
            .toolbarBackground(Color.black, for: .bottomBar)
            .preferredColorScheme(.dark)
            .onAppear {
                manager.requestAccessAndFetch()
            }
            .onChange(of: manager.errorMessage) { _, message in
                showDeleteError = message != nil
            }
            .alert(
                "Delete Selected Photos?",
                isPresented: $showDeleteConfirmation
            ) {
                Button("Cancel", role: .cancel) { }

                Button("Delete", role: .destructive) {
                    manager.deleteSelected { success in
                        if success {
                            isSelecting = false
                        }
                    }
                }
            } message: {
                Text(
                    "Delete \(manager.selectedCount) selected photo(s) " +
                    "from your iPhone photo library?"
                )
            }
            .alert(
                "Photo Error",
                isPresented: $showDeleteError
            ) {
                Button("OK", role: .cancel) {
                    manager.errorMessage = nil
                }
            } message: {
                Text(
                    manager.errorMessage ??
                    "The requested photo operation failed."
                )
            }
            .sheet(
                item: $selectedPhoto,
                onDismiss: {
                    manager.refresh()
                }
            ) { selected in
                PhotoDetailView(
                    asset: selected.asset,
                    fallbackImage: nil,
                    manager: manager
                )
                .id(selected.id)
            }
        }
    }

    // MARK: - Photo Grid

    private var photoGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(
                    manager.assets,
                    id: \.localIdentifier
                ) { asset in
                    PhotoThumbnailView(
                        asset: asset,
                        isSelected: manager.isSelected(asset),
                        isSelecting: isSelecting
                    ) {
                        if isSelecting {
                            manager.toggleSelection(asset)
                        } else {
                            selectedPhoto = SelectedPhoto(
                                asset: asset
                            )
                        }
                    }
                }
            }
            .padding(3)
        }
        .background(Color.black)
    }

    // MARK: - Permission View

    private var permissionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text("Photo Access Required")
                .font(.title3.bold())

            Text(
                "Allow this app to access your Photos library " +
                "to view and manage your pictures."
            )
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)

            if manager.authorizationStatus == .notDetermined {
                Button("Allow Photo Access") {
                    manager.requestAccessAndFetch()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Open Settings") {
                    guard let url = URL(
                        string: UIApplication.openSettingsURLString
                    ) else {
                        return
                    }

                    UIApplication.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity
        )
    }
}

// MARK: - Photo Thumbnail

private struct PhotoThumbnailView: View {
    let asset: PHAsset
    let isSelected: Bool
    let isSelecting: Bool
    let onTap: () -> Void

    @Environment(\.displayScale) private var displayScale

    @State private var thumbnail: UIImage?
    @State private var requestID: PHImageRequestID =
        PHInvalidImageRequestID

    private let imageManager = PHCachingImageManager()

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topTrailing) {
                GeometryReader { geometry in
                    Group {
                        if let thumbnail {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Rectangle()
                                .fill(Color(white: 0.15))
                                .overlay {
                                    Image(systemName: "photo")
                                        .foregroundStyle(.gray)
                                }
                        }
                    }
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height
                    )
                    .clipped()
                }
                .aspectRatio(1, contentMode: .fit)

                if isSelecting {
                    Image(
                        systemName: isSelected
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                    .font(.system(size: 24, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        .white,
                        isSelected
                            ? .blue
                            : .black.opacity(0.4)
                    )
                    .padding(7)
                }
            }
            .overlay {
                if isSelected && isSelecting {
                    Color.blue.opacity(0.22)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: asset.localIdentifier) {
            loadThumbnail()
        }
        .onDisappear {
            if requestID != PHInvalidImageRequestID {
                imageManager.cancelImageRequest(requestID)
                requestID = PHInvalidImageRequestID
            }
        }
    }

    private func loadThumbnail() {
        if requestID != PHInvalidImageRequestID {
            imageManager.cancelImageRequest(requestID)
            requestID = PHInvalidImageRequestID
        }

        thumbnail = nil

        let scale = displayScale
        let targetSize = CGSize(
            width: 240 * scale,
            height: 240 * scale
        )

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        requestID = imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { image, info in
            if let cancelled = info?[PHImageCancelledKey] as? Bool,
               cancelled {
                return
            }

            if let error = info?[PHImageErrorKey] as? Error {
                print(
                    "Thumbnail load error: \(error.localizedDescription)"
                )
                return
            }

            guard let image else { return }

            DispatchQueue.main.async {
                self.thumbnail = image
            }
        }
    }
}

// MARK: - Shared Photo Preview

struct PhotoDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let asset: PHAsset?
    let fallbackImage: UIImage?
    let manager: PhotoManager?

    @State private var photo: UIImage?
    @State private var requestID: PHImageRequestID =
        PHInvalidImageRequestID

    @State private var zoomScale: CGFloat = 1
    @State private var savedZoomScale: CGFloat = 1
    @State private var photoOffset: CGSize = .zero
    @State private var savedPhotoOffset: CGSize = .zero

    @State private var showDeleteConfirmation = false
    @State private var showDeleteError = false
    @State private var isDeletingThisPhoto = false
    @State private var loadError: String?

    private let imageManager = PHImageManager.default()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let photo {
                    GeometryReader { geometry in
                        Image(uiImage: photo)
                            .resizable()
                            .scaledToFit()
                            .frame(
                                width: geometry.size.width,
                                height: geometry.size.height
                            )
                            .scaleEffect(zoomScale)
                            .offset(photoOffset)
                            .contentShape(Rectangle())
                            .simultaneousGesture(
                                MagnificationGesture()
                                    .onChanged { value in
                                        let newScale = min(
                                            max(savedZoomScale * value, 1),
                                            6
                                        )

                                        zoomScale = newScale

                                        if newScale <= 1 {
                                            photoOffset = .zero
                                            savedPhotoOffset = .zero
                                        } else {
                                            photoOffset = clampedOffset(
                                                savedPhotoOffset,
                                                photo: photo,
                                                viewport: geometry.size,
                                                scale: newScale
                                            )
                                        }
                                    }
                                    .onEnded { _ in
                                        savedZoomScale = zoomScale
                                        savedPhotoOffset = photoOffset
                                    }
                            )
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 2)
                                    .onChanged { value in
                                        guard zoomScale > 1 else {
                                            return
                                        }

                                        let proposed = CGSize(
                                            width: savedPhotoOffset.width
                                                + value.translation.width,
                                            height: savedPhotoOffset.height
                                                + value.translation.height
                                        )

                                        photoOffset = clampedOffset(
                                            proposed,
                                            photo: photo,
                                            viewport: geometry.size,
                                            scale: zoomScale
                                        )
                                    }
                                    .onEnded { _ in
                                        savedPhotoOffset = photoOffset
                                    }
                            )
                            .onTapGesture(count: 2) {
                                withAnimation(
                                    .easeInOut(duration: 0.2)
                                ) {
                                    zoomScale = 1
                                    savedZoomScale = 1
                                    photoOffset = .zero
                                    savedPhotoOffset = .zero
                                }
                            }
                            .frame(
                                width: geometry.size.width,
                                height: geometry.size.height
                            )
                    }
                } else if let loadError {
                    VStack(spacing: 14) {
                        Image(
                            systemName: "exclamationmark.triangle"
                        )
                        .font(.largeTitle)

                        Text("Could Not Load Photo")

                        Text(loadError)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)

                        Button("Try Again") {
                            loadPhoto()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.white)

                        Text("Loading photo…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showDeleteConfirmation = true
                    } label: {
                        if isDeletingThisPhoto {
                            ProgressView()
                                .tint(.red)
                        } else {
                            Image(systemName: "trash")
                                .font(
                                    .system(
                                        size: 18,
                                        weight: .semibold
                                    )
                                )
                                .foregroundStyle(.red)
                        }
                    }
                    .disabled(
                        asset == nil ||
                        manager == nil ||
                        isDeletingThisPhoto
                    )
                    .accessibilityLabel("Delete photo")
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .preferredColorScheme(.dark)
            .alert(
                "Delete This Photo?",
                isPresented: $showDeleteConfirmation
            ) {
                Button("Cancel", role: .cancel) { }

                Button("Delete", role: .destructive) {
                    deleteThisPhoto()
                }
            } message: {
                Text(
                    "This photo will be deleted from your Photos library."
                )
            }
            .alert(
                "Could Not Delete Photo",
                isPresented: $showDeleteError
            ) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(
                    manager?.errorMessage ??
                    "The photo could not be deleted."
                )
            }
            .onAppear {
                if let fallbackImage {
                    photo = fallbackImage
                }

                if asset != nil {
                    loadPhoto()
                } else if fallbackImage == nil {
                    loadError = "No photo is available to display."
                }
            }
            .onDisappear {
                cancelImageRequest()
            }
        }
    }

    // MARK: - Clamp Image Movement

    private func clampedOffset(
        _ proposed: CGSize,
        photo: UIImage,
        viewport: CGSize,
        scale: CGFloat
    ) -> CGSize {
        guard photo.size.width > 0,
              photo.size.height > 0 else {
            return .zero
        }

        let fitRatio = min(
            viewport.width / photo.size.width,
            viewport.height / photo.size.height
        )

        let displayedWidth = photo.size.width * fitRatio * scale
        let displayedHeight = photo.size.height * fitRatio * scale

        let maxX = max(
            0,
            (displayedWidth - viewport.width) / 2
        )

        let maxY = max(
            0,
            (displayedHeight - viewport.height) / 2
        )

        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }

    // MARK: - Load Photo

    private func loadPhoto() {
        guard let asset else { return }

        cancelImageRequest()
        loadError = nil

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        options.version = .current

        requestID = imageManager.requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            if let cancelled = info?[PHImageCancelledKey] as? Bool,
               cancelled {
                return
            }

            if let error = info?[PHImageErrorKey] as? Error {
                DispatchQueue.main.async {
                    loadError = error.localizedDescription
                }
                return
            }

            if let inCloud = info?[PHImageResultIsInCloudKey] as? Bool,
               inCloud,
               image == nil {
                DispatchQueue.main.async {
                    loadError =
                        "This photo is stored in iCloud and could not " +
                        "be downloaded. Check your internet connection " +
                        "and try again."
                }
                return
            }

            guard let image else { return }

            DispatchQueue.main.async {
                photo = image
                loadError = nil
            }
        }
    }

    // MARK: - Cancel Image Request

    private func cancelImageRequest() {
        if requestID != PHInvalidImageRequestID {
            imageManager.cancelImageRequest(requestID)
            requestID = PHInvalidImageRequestID
        }
    }

    // MARK: - Delete Photo

    private func deleteThisPhoto() {
        guard let asset, let manager else {
            return
        }

        isDeletingThisPhoto = true

        manager.delete(asset: asset) { success in
            isDeletingThisPhoto = false

            if success {
                dismiss()
            } else {
                showDeleteError = true
            }
        }
    }
}
