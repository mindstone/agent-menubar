import SwiftUI

struct MenuBarLabel: View {
    let state: MenuBarState

    var body: some View {
        switch state {
        case .idle:
            Image(systemName: "wand.and.stars")
        case .tracking(let count):
            HStack(spacing: 2) {
                Image(systemName: "wand.and.stars")
                Text("\(count)")
            }
        case .attention(let count, _):
            HStack(spacing: 2) {
                Image(systemName: "exclamationmark.bubble.fill")
                Text("\(count)")
            }
            .foregroundStyle(.orange)
        }
    }
}
