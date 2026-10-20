import SwiftUI
import Observation
import CoreMotion

// MARK: - Central Camera Controls

@MainActor
@Observable
final class CentralManager {

    // MARK: Grid Lines

    var showGrid = false

    func toggleGrid() {
        showGrid.toggle()
    }

    func setGrid(_ enabled: Bool) {
        showGrid = enabled
    }

    // MARK: Horizon Level

    var showLevel = false

    private(set) var levelAngle: Double = 0
    private(set) var isLevel = true
    private(set) var isMotionAvailable = true

    @ObservationIgnored
    private let motionManager = CMMotionManager()

    @ObservationIgnored
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "CameraHorizonLevelQueue"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private let levelTolerance = 1.5

    func toggleLevel() {
        setLevel(!showLevel)
    }

    func setLevel(_ enabled: Bool) {
        showLevel = enabled

        if enabled {
            startLevelUpdates()
        } else {
            stopLevelUpdates()
        }
    }

    private func startLevelUpdates() {
        guard motionManager.isDeviceMotionAvailable else {
            isMotionAvailable = false
            return
        }

        isMotionAvailable = true

        guard !motionManager.isDeviceMotionActive else {
            return
        }

        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0

        motionManager.startDeviceMotionUpdates(
            to: motionQueue
        ) { [weak self] motion, error in

            guard let motion, error == nil else {
                return
            }

            let angle =
                motion.attitude.roll * 180.0 / .pi

            Task { @MainActor [weak self] in
                guard let self, self.showLevel else {
                    return
                }

                self.levelAngle = angle
                self.isLevel =
                    abs(angle) <= self.levelTolerance
            }
        }
    }

    private func stopLevelUpdates() {
        motionManager.stopDeviceMotionUpdates()

        levelAngle = 0
        isLevel = true
    }
}

// MARK: - Camera Grid Overlay

struct CameraGridOverlay: View {

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let width = geometry.size.width
                let height = geometry.size.height

                // Vertical thirds
                path.move(
                    to: CGPoint(x: width / 3, y: 0)
                )
                path.addLine(
                    to: CGPoint(x: width / 3, y: height)
                )

                path.move(
                    to: CGPoint(x: width * 2 / 3, y: 0)
                )
                path.addLine(
                    to: CGPoint(x: width * 2 / 3, y: height)
                )

                // Horizontal thirds
                path.move(
                    to: CGPoint(x: 0, y: height / 3)
                )
                path.addLine(
                    to: CGPoint(x: width, y: height / 3)
                )

                path.move(
                    to: CGPoint(x: 0, y: height * 2 / 3)
                )
                path.addLine(
                    to: CGPoint(x: width, y: height * 2 / 3)
                )
            }
            .stroke(.white.opacity(0.8), lineWidth: 0.8)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Reusable Horizon Level Indicator

struct CameraHorizonLevelIndicator: View {

    let angle: Double
    let isLevel: Bool
    let isAvailable: Bool

    // Customisable line appearance.
    var lineLength: CGFloat = 90
    var lineThickness: CGFloat = 1.5

    private var indicatorColor: Color {
        isLevel ? .yellow : .white
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if isAvailable {
                    HStack(spacing: 0) {

                        // Left line
                        Capsule()
                            .fill(indicatorColor)
                            .frame(
                                width: lineLength,
                                height: lineThickness
                            )

                        // Centre circle
                        Circle()
                            .stroke(
                                indicatorColor,
                                lineWidth: 3
                            )
                            .frame(
                                width: 16,
                                height: 16
                            )
                            .overlay {
                                Circle()
                                    .fill(indicatorColor)
                                    .frame(
                                        width: 3,
                                        height: 3
                                    )
                            }
                            .opacity(0.1)

                        // Right line
                        Capsule()
                            .fill(indicatorColor)
                            .frame(
                                width: lineLength,
                                height: lineThickness
                            )
                    }
                    .shadow(
                        color: .black.opacity(0.7),
                        radius: 3
                    )
                    .rotationEffect(
                        .degrees(-angle),
                        anchor: .center
                    )
                    .position(
                        x: geometry.size.width / 2,
                        y: geometry.size.height / 2
                    )

                } else {
                    Text("Level unavailable")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.65))
                        .clipShape(Capsule())
                        .position(
                            x: geometry.size.width / 2,
                            y: geometry.size.height / 2
                        )
                }
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            isAvailable
                ? (
                    isLevel
                        ? "Camera is level"
                        : "Camera is tilted"
                )
                : "Horizon level unavailable"
        )
    }
}
