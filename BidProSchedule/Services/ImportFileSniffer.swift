import Foundation

enum ImportFileSniffer {
    static func sniffPDFSignature(in data: Data) -> (isPDF: Bool, header: String) {
        let prefix = data.prefix(8)
        let ascii = String(decoding: prefix, as: UTF8.self)
        let sanitizedASCII = ascii.unicodeScalars
            .map { scalar in
                let value = scalar.value
                let isPrintableASCII = scalar.isASCII && value >= 32 && value <= 126
                return isPrintableASCII ? String(scalar) : "."
            }
            .joined()
        let hex = prefix.map { String(format: "%02X", $0) }.joined(separator: " ")
        let header = "\(sanitizedASCII) [\(hex)]"
        let isPDF = data.starts(with: [0x25, 0x50, 0x44, 0x46, 0x2D]) // %PDF-
        return (isPDF, header)
    }
}
