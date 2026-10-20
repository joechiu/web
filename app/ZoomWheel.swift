
import SwiftUI

// Restricts hit testing to the visible 3/4-circle sector.
// The circle's centre is at the bottom-right corner.
private struct ZoomWheelHitShape: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let pivot = CGPoint(x: rect.maxX, y: rect.maxY)

        var path = Path()
        path.move(to: pivot)
        path.addArc(
            center: pivot,
            radius: min(radius, min(rect.width, rect.height)),
            startAngle: .degrees(-90),
            endAngle: .degrees(-360),
            clockwise: true
        )
        path.closeSubpath()

        return path
    }
}

struct CircularZoomWheel: View {
    let zoom: Double
    let maxZoom: Double
    let onZoomChanged: (Double) -> Void

    private let dialSize: CGFloat = 360
    private let radius: CGFloat = 300
    private let labelRadius: CGFloat = 235

    // Increase this for faster zoom response.
    private let spinSensitivity: Double = 1.8

    @State private var lastDragAngle: Double?
    @State private var lastReportedZoom: Double = 1.0
    @State private var wheelbgcolor: Double = 0.5

    private var safeMaxZoom: Double {
        max(1.0, maxZoom)
    }

    private var zoomRange: Double {
        safeMaxZoom - 1.0
    }

    // 3/4-circle: 270 degrees.
    private let startAngle = Double.pi / 2.0
    private let scaleAngleRange = 3.0 * Double.pi / 2.0
    private let markerAngle = -3.0 * Double.pi / 4.0

    private var zoomFraction: Double {
        guard zoomRange > 0 else { return 0 }
        return min(max((zoom - 1.0) / zoomRange, 0), 1)
    }

    private var scaleRotation: Double {
        markerAngle - (
            startAngle + zoomFraction * scaleAngleRange
        )
    }

    var body: some View {
        ZStack {
            // Translucent gray 3/4-circle background.
            Canvas { context, size in
                let pivot = CGPoint(
                    x: size.width,
                    y: size.height
                )

                var sector = Path()
                sector.move(to: pivot)
                sector.addArc(
                    center: pivot,
                    radius: radius,
                    startAngle: .degrees(-90),
                    endAngle: .degrees(-360),
                    clockwise: true
                )
                sector.closeSubpath()

                context.fill(
                    sector,
                    with: .color(.black.opacity(wheelbgcolor))
                )
            }
            .frame(width: dialSize, height: dialSize)

            // Rotating 3/4-circle scale and radial labels.
            Canvas { context, size in
                context.translateBy(
                    x: size.width,
                    y: size.height
                )
                context.rotate(by: .radians(scaleRotation))

                drawScale(context: context)
            }
            .frame(width: dialSize, height: dialSize)

            // Fixed yellow selection marker.
            Circle()
                .fill(.black.opacity(0.85))
                .frame(width: 22, height: 22)
                .overlay {
                    Circle()
                        .fill(.yellow)
                        .frame(width: 16, height: 16)
                }
                .position(
                    x: dialSize + radius * cos(markerAngle),
                    y: dialSize + radius * sin(markerAngle)
                )
                .allowsHitTesting(false)

            // Fixed current zoom value.
            Text(String(format: "%.1f×", zoom))
                .font(
                    .system(
                        size: 25,
                        weight: .semibold,
                        design: .rounded
                    )
                )
                .foregroundColor(.white)
                .position(
                    x: dialSize - 105,
                    y: dialSize - 105
                )
                .allowsHitTesting(false)
        }
        .frame(width: dialSize, height: dialSize)
        .clipped()
        .contentShape(ZoomWheelHitShape(radius: radius))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let currentAngle = fingerAngle(value.location)

                    guard let previousAngle = lastDragAngle else {
                        lastDragAngle = currentAngle
                        lastReportedZoom = zoom
                        return
                    }

                    var delta = currentAngle - previousAngle

                    if delta > Double.pi {
                        delta -= 2.0 * Double.pi
                    } else if delta < -Double.pi {
                        delta += 2.0 * Double.pi
                    }

                    lastDragAngle = currentAngle

                    guard zoomRange > 0 else { return }

                    let zoomDelta =
                        -(delta / scaleAngleRange)
                        * zoomRange
                        * spinSensitivity

                    let newZoom = min(
                        max(
                            lastReportedZoom + zoomDelta,
                            1.0
                        ),
                        safeMaxZoom
                    )

                    guard abs(newZoom - lastReportedZoom) > 0.001 else {
                        return
                    }

                    lastReportedZoom = newZoom
                    onZoomChanged(newZoom)
                }
                .onEnded { _ in
                    lastDragAngle = nil
                }
        )
        .onChange(of: zoom) { _, newZoom in
            lastReportedZoom = newZoom
        }
        .accessibilityElement()
        .accessibilityLabel("Camera zoom dial")
        .accessibilityValue(
            String(format: "%.1f times", zoom)
        )
        .accessibilityHint(
            "Drag along the dial to change zoom"
        )
    }

    private func drawScale(context: GraphicsContext) {
        // Draw the 3/4-circle arc.
        var arc = Path()
        arc.addArc(
            center: .zero,
            radius: radius,
            startAngle: .radians(startAngle),
            endAngle: .radians(startAngle + scaleAngleRange),
            clockwise: false
        )

        context.stroke(
            arc,
            with: .color(.white.opacity(0.8)),
            lineWidth: 2
        )

        // Draw tick marks along the 3/4-circle.
        let tickCount = max(40, Int(zoomRange * 10))

        for index in 0...tickCount {
            let fraction = Double(index) / Double(tickCount)
            let angle = startAngle + fraction * scaleAngleRange
            let tickZoom = 1.0 + zoomRange * fraction

            let isInteger =
                abs(tickZoom - tickZoom.rounded()) < 0.0001
            let isMajor = index % 5 == 0

            let tickLength: CGFloat =
                isInteger || isMajor ? 25 : 13

            let innerRadius = radius - tickLength

            let innerPoint = CGPoint(
                x: cos(angle) * innerRadius,
                y: sin(angle) * innerRadius
            )

            let outerPoint = CGPoint(
                x: cos(angle) * radius,
                y: sin(angle) * radius
            )

            var tick = Path()
            tick.move(to: innerPoint)
            tick.addLine(to: outerPoint)

            context.stroke(
                tick,
                with: .color(
                    isInteger ? .white : .white.opacity(0.55)
                ),
                lineWidth: isInteger ? 2 : 1
            )
        }

        // Whole-number labels aligned radially with the scale.
        // Numbers have no multiplication-sign suffix.
        guard zoomRange > 0 else { return }

        let firstInteger = 1
        let lastInteger = Int(floor(safeMaxZoom))

        if firstInteger <= lastInteger {
            for zoomValue in firstInteger...lastInteger {
                let fraction =
                    (Double(zoomValue) - 1.0) / zoomRange

                // Use the same angle as the corresponding scale tick.
                let angle =
                    startAngle + fraction * scaleAngleRange

                // Position the number inward from the outer tick.
                let labelPoint = CGPoint(
                    x: cos(angle) * labelRadius,
                    y: sin(angle) * labelRadius
                )

                var labelContext = context
                labelContext.translateBy(
                    x: labelPoint.x,
                    y: labelPoint.y
                )

                // Rotate text to follow its radial line.
                var textAngle = angle + Double.pi / 2.0

                // Normalize the text angle to 0...2π.
                let fullTurn = 2.0 * Double.pi
                var uprightAngle = textAngle
                    .truncatingRemainder(dividingBy: fullTurn)

                if uprightAngle < 0 {
                    uprightAngle += fullTurn
                }

                labelContext.rotate(by: .radians(textAngle))

                labelContext.draw(
                    Text("\(zoomValue)")
                        .font(
                            .system(
                                size: 14,
                                weight: .semibold,
                                design: .rounded
                            )
                        )
                        .foregroundColor(.white),
                    at: .zero,
                    anchor: .center
                )
            }
        }
    }

    private func fingerAngle(_ location: CGPoint) -> Double {
        atan2(
            Double(location.y - dialSize),
            Double(location.x - dialSize)
        )
    }
}
