import BlockEngine
import SwiftUI

/// Couleurs et dimensions de l'interface.
enum Theme {
    static let blockHeight: CGFloat = 52
    static let canvasBackground = Color(red: 0.10, green: 0.11, blue: 0.15)
    static let panelBackground = Color(red: 0.15, green: 0.16, blue: 0.21)
    static let accent = Color(red: 0.36, green: 0.78, blue: 0.62)
    /// Nom de l'espace de coordonnées du contenu du canvas.
    static let canvasSpace = "canvas"

    static func color(for category: BlockCategory) -> Color {
        switch category {
        case .triggers: return Color(red: 0.93, green: 0.66, blue: 0.16)
        case .actions: return Color(red: 0.24, green: 0.55, blue: 0.92)
        case .control: return Color(red: 0.89, green: 0.45, blue: 0.22)
        case .sensors: return Color(red: 0.20, green: 0.68, blue: 0.62)
        case .data: return Color(red: 0.62, green: 0.42, blue: 0.86)
        }
    }

    static func symbol(for category: BlockCategory) -> String {
        switch category {
        case .triggers: return "bolt.fill"
        case .actions: return "gearshape.fill"
        case .control: return "repeat"
        case .sensors: return "sensor.fill"
        case .data: return "number"
        }
    }

    /// Pastille de couleur d'un choix « couleur » (lumière ou capteur), nil pour les autres choix.
    static func swatch(for optionID: String) -> Color? {
        switch optionID {
        case "off": return Color(white: 0.25)
        case "black": return .black
        case "pink": return Color(red: 1.0, green: 0.45, blue: 0.75)
        case "purple": return Color(red: 0.62, green: 0.32, blue: 0.90)
        case "blue": return Color(red: 0.15, green: 0.35, blue: 0.95)
        case "lightBlue": return Color(red: 0.45, green: 0.72, blue: 1.0)
        case "cyan": return Color(red: 0.20, green: 0.85, blue: 0.80)
        case "green": return Color(red: 0.20, green: 0.78, blue: 0.30)
        case "yellow": return Color(red: 0.98, green: 0.85, blue: 0.15)
        case "orange": return Color(red: 1.0, green: 0.55, blue: 0.10)
        case "red": return Color(red: 0.92, green: 0.20, blue: 0.20)
        case "white": return .white
        default: return nil
        }
    }

    /// Nombre affiché sans décimales inutiles.
    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e9 {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: ".", with: ",")
    }
}

/// Forme à bouts pointus des blocs « condition ».
struct PointedShape: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = min(rect.height / 2, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

extension BlockShape {
    /// Contour du bloc.
    var outline: AnyShape {
        switch self {
        case .trigger:
            return AnyShape(UnevenRoundedRectangle(topLeadingRadius: 26, bottomLeadingRadius: 26,
                                                   bottomTrailingRadius: 10, topTrailingRadius: 10))
        case .statement, .container:
            return AnyShape(RoundedRectangle(cornerRadius: 10))
        case .number:
            return AnyShape(Capsule())
        case .boolean:
            return AnyShape(PointedShape())
        }
    }
}
