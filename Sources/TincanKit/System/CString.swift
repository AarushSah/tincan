import Foundation

extension String {
    /// The text in a C buffer up to its first NUL, decoded as UTF-8 with invalid bytes
    /// repaired, as `String(cString:)` read a `[CChar]` before Swift 6 deprecated that form.
    init(nulTerminated buffer: [CChar]) {
        self.init(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
