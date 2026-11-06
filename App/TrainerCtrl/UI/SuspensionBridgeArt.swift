import SwiftUI

/// A line drawing of the Mackinac Bridge: two tall towers, a long main span
/// hung from sagging cables, side spans down to the anchorages, and the deck
/// running off both edges. Background art for the home screen.
struct SuspensionBridgeArt: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let deckY = h * 0.72
            let towerTop = h * 0.08
            let leftTower = w * 0.28, rightTower = w * 0.72
            let leftAnchor = w * 0.06, rightAnchor = w * 0.94
            let anchorY = deckY - h * 0.03
            let sagY = deckY - h * 0.05
            let line = max(1.5, w / 260)

            func stroke(_ path: Path, _ width: CGFloat, _ opacity: Double = 1) {
                ctx.stroke(path, with: .color(.primary.opacity(opacity)),
                           style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }

            // Main cable height at x, piecewise: side span, main span, side span.
            func cableY(_ x: CGFloat) -> CGFloat {
                if x <= leftTower {
                    let t = (x - leftAnchor) / (leftTower - leftAnchor)
                    return anchorY + (towerTop - anchorY) * (t * t * 0.55 + t * 0.45)
                } else if x >= rightTower {
                    let t = (rightAnchor - x) / (rightAnchor - rightTower)
                    return anchorY + (towerTop - anchorY) * (t * t * 0.55 + t * 0.45)
                } else {
                    let t = (x - leftTower) / (rightTower - leftTower) * 2 - 1   // -1…1
                    return sagY + (towerTop - sagY) * t * t
                }
            }

            // Suspenders
            var hangers = Path()
            var x = leftAnchor + w * 0.025
            while x < rightAnchor {
                if abs(x - leftTower) > w * 0.008 && abs(x - rightTower) > w * 0.008 {
                    hangers.move(to: CGPoint(x: x, y: cableY(x)))
                    hangers.addLine(to: CGPoint(x: x, y: deckY))
                }
                x += w * 0.018
            }
            stroke(hangers, line * 0.45, 0.6)

            // Cable
            var cable = Path()
            cable.move(to: CGPoint(x: leftAnchor, y: anchorY))
            var cx = leftAnchor
            while cx <= rightAnchor {
                cable.addLine(to: CGPoint(x: cx, y: cableY(cx)))
                cx += w / 200
            }
            cable.addLine(to: CGPoint(x: rightAnchor, y: anchorY))
            stroke(cable, line)

            // Deck with a stiffening truss under it, running off both edges
            let trussDepth = h * 0.035
            var deck = Path()
            deck.move(to: CGPoint(x: 0, y: deckY)); deck.addLine(to: CGPoint(x: w, y: deckY))
            deck.move(to: CGPoint(x: 0, y: deckY + trussDepth)); deck.addLine(to: CGPoint(x: w, y: deckY + trussDepth))
            stroke(deck, line)
            var truss = Path()
            var tx: CGFloat = 0, up = true
            truss.move(to: CGPoint(x: 0, y: deckY + trussDepth))
            while tx < w {
                tx += trussDepth
                truss.addLine(to: CGPoint(x: tx, y: up ? deckY : deckY + trussDepth))
                up.toggle()
            }
            stroke(truss, line * 0.5, 0.7)

            // Towers: two legs, crossbeams, down to piers in the water
            let waterY = h * 0.94
            for tower in [leftTower, rightTower] {
                let half = w * 0.012
                var legs = Path()
                legs.move(to: CGPoint(x: tower - half, y: towerTop)); legs.addLine(to: CGPoint(x: tower - half * 1.3, y: waterY))
                legs.move(to: CGPoint(x: tower + half, y: towerTop)); legs.addLine(to: CGPoint(x: tower + half * 1.3, y: waterY))
                for f in [0.0, 0.22, 0.44] {
                    let y = towerTop + (deckY - towerTop) * f
                    legs.move(to: CGPoint(x: tower - half, y: y)); legs.addLine(to: CGPoint(x: tower + half, y: y))
                }
                stroke(legs, line * 1.4)
            }

            // Approach piers and the water line
            var piers = Path()
            for px in stride(from: w * 0.1, to: w, by: w * 0.11) where abs(px - leftTower) > w * 0.06 && abs(px - rightTower) > w * 0.06 {
                piers.move(to: CGPoint(x: px, y: deckY + trussDepth)); piers.addLine(to: CGPoint(x: px, y: waterY))
            }
            stroke(piers, line * 0.8, 0.7)
            var water = Path()
            water.move(to: CGPoint(x: 0, y: waterY)); water.addLine(to: CGPoint(x: w, y: waterY))
            stroke(water, line * 0.6, 0.5)
        }
        .accessibilityHidden(true)
    }
}
