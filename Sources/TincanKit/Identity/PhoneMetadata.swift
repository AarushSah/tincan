import Foundation
import MachO
import PhoneNumberKit

/// Google's libphonenumber metadata, through PhoneNumberKit, for numbers written without a
/// country code outside North America: which digits are a country code, a trunk or
/// international prefix, or the number itself, region by region.
enum PhoneMetadata {
    /// The parser, built on first use. PhoneNumberKit locks its own caches, and tincan
    /// parses from one task at a time.
    nonisolated(unsafe) static let utility = PhoneNumberUtility(metadataCallback: { try embedded ?? PhoneNumberUtility.defaultMetadataCallback() })

    /// The metadata linked into the tincan executable (`__TEXT,__tincan_phones`, from
    /// Support/PhoneNumberMetadata.json), so an installed tincan needs no resource bundle
    /// beside it. Nil in other programs, such as the tests, which read PhoneNumberKit's own.
    static var embedded: Data? {
        guard let header = _dyld_get_image_header(0) else { return nil }
        var size: UInt = 0
        let raw = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
        guard let bytes = getsectiondata(raw, "__TEXT", "__tincan_phones", &size), size > 0 else { return nil }
        return Data(bytes: bytes, count: Int(size))
    }

    /// `digits`, written without `+`, as a number in `region`: its calling code and E.164
    /// form. Nil when the digits aren't a number there, by the region's patterns.
    static func parse(_ digits: String, region: String) -> (countryCode: String, e164: String)? {
        guard let number = try? utility.parse(digits, withRegion: region, ignoreType: true) else { return nil }
        return (String(number.countryCode), utility.format(number, toType: .e164))
    }
}
