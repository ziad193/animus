import SwiftUI
import StudyCore

/// The app's colours, kept in one place so themes can swap them later.
enum Palette {
    static let new = Color.blue
    static let learning = Color.orange
    static let review = Color.green

    static func grade(_ rating: Rating) -> Color {
        switch rating {
        case .again: .red
        case .hard: .orange
        case .good: .green
        case .easy: .blue
        }
    }
}
