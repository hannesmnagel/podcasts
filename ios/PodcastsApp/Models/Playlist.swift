import Foundation
import SwiftData

@Model
final class Playlist {
    var id: UUID = UUID()
    var name: String = ""
    var sortIndex: Int = 0
    var smartKind: String?

    init(id: UUID = UUID(), name: String, sortIndex: Int, smartKind: String? = nil) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
        self.smartKind = smartKind
    }
}
