//
//  WindowPlacement.swift
//  WindowBuddy
//
//  Created by Codex on 01/06/2026.
//

import CoreGraphics

enum WindowPlacement: String, CaseIterable, Identifiable {
    case left
    case right
    case top
    case bottom
    case center
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .top: "Top"
        case .bottom: "Bottom"
        case .center: "Center"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        }
    }

    var symbolName: String {
        switch self {
        case .left: "rectangle.leadinghalf.inset.filled"
        case .right: "rectangle.trailinghalf.inset.filled"
        case .top: "rectangle.tophalf.inset.filled"
        case .bottom: "rectangle.bottomhalf.inset.filled"
        case .center: "rectangle.center.inset.filled"
        case .topLeft: "arrow.up.left.square"
        case .topRight: "arrow.up.right.square"
        case .bottomLeft: "arrow.down.left.square"
        case .bottomRight: "arrow.down.right.square"
        }
    }

    var variants: [WindowLayoutVariant] {
        switch self {
        case .left, .right:
            [
                WindowLayoutVariant(name: "1/2", widthFraction: 0.5, heightFraction: 1.0),
                WindowLayoutVariant(name: "2/3", widthFraction: 2.0 / 3.0, heightFraction: 1.0),
                WindowLayoutVariant(name: "1/3", widthFraction: 1.0 / 3.0, heightFraction: 1.0)
            ]
        case .top, .bottom:
            [
                WindowLayoutVariant(name: "1/2", widthFraction: 1.0, heightFraction: 0.5),
                WindowLayoutVariant(name: "2/3", widthFraction: 1.0, heightFraction: 2.0 / 3.0),
                WindowLayoutVariant(name: "1/3", widthFraction: 1.0, heightFraction: 1.0 / 3.0)
            ]
        case .center:
            [
                WindowLayoutVariant(name: "1/3", widthFraction: 1.0 / 3.0, heightFraction: 1.0),
                WindowLayoutVariant(name: "1/2", widthFraction: 0.5, heightFraction: 1.0),
                WindowLayoutVariant(name: "2/3", widthFraction: 2.0 / 3.0, heightFraction: 1.0)
            ]
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            [
                WindowLayoutVariant(name: "Small", widthFraction: 1.0 / 3.0, heightFraction: 1.0 / 3.0),
                WindowLayoutVariant(name: "1/4", widthFraction: 0.5, heightFraction: 0.5),
                WindowLayoutVariant(name: "Large", widthFraction: 2.0 / 3.0, heightFraction: 2.0 / 3.0)
            ]
        }
    }

    func frame(in availableFrame: CGRect, using variant: WindowLayoutVariant) -> CGRect {
        let width = availableFrame.width * variant.widthFraction
        let height = availableFrame.height * variant.heightFraction

        let x: CGFloat
        switch self {
        case .left, .top, .bottom, .topLeft, .bottomLeft:
            x = availableFrame.minX
        case .right, .topRight, .bottomRight:
            x = availableFrame.maxX - width
        case .center:
            x = availableFrame.midX - (width / 2)
        }

        let y: CGFloat
        switch self {
        case .top, .left, .right, .center, .topLeft, .topRight:
            y = availableFrame.minY
        case .bottom, .bottomLeft, .bottomRight:
            y = availableFrame.maxY - height
        }

        return CGRect(x: x.rounded(.toNearestOrAwayFromZero),
                      y: y.rounded(.toNearestOrAwayFromZero),
                      width: width.rounded(.toNearestOrAwayFromZero),
                      height: height.rounded(.toNearestOrAwayFromZero))
    }
}

struct WindowLayoutVariant: Hashable {
    let name: String
    let widthFraction: CGFloat
    let heightFraction: CGFloat
}
