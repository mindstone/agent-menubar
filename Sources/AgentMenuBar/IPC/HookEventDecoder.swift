import Foundation

enum HookEventDecoder {
    static func decode(_ line: Data) -> HookEvent? {
        let dec = JSONDecoder()
        return try? dec.decode(HookEvent.self, from: line)
    }
}
