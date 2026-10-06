import Foundation

/// A phone number normalized for matching across Messages, call history and Contacts.
///
/// Messages mostly stores E.164 (`+14155550142`). Contacts stores whatever a person typed
/// (`(415) 555-0142`, `0412 345 678`). Call history stores E.164 or national digits with an
/// ISO country. tincan normalizes all of them to E.164 when the country can be known and
/// keeps the national significant number for a conservative fallback comparison.
public struct PhoneNumber: Hashable, Sendable, CustomStringConvertible {
    /// `+<country code><national number>` when the country is known; otherwise the digits.
    public let normalized: String
    /// Calling code without `+`, when known.
    public let countryCode: String?
    /// National significant number: the digits after the country code and trunk prefix.
    public let nationalNumber: String
    /// Extension digits, when the input had one (`x123`, `ext. 123`).
    public let phoneExtension: String?

    public var isE164: Bool { countryCode != nil }
    public var description: String { normalized }

    /// Short codes (5- or 6-digit senders used by businesses) and service numbers.
    public var isShortCode: Bool { countryCode == nil && nationalNumber.count <= 6 }

    /// Parses `input` as typed by a person or stored by Apple. `region` is an ISO 3166 code
    /// (`US`, `JP`) used for numbers without a country code. Returns nil for text that is
    /// not a phone number, such as an email address.
    public static func parse(_ input: String, region: String?) -> PhoneNumber? {
        var text = plainCharacters(input).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("tel:") { text = String(text.dropFirst(4)) }
        if text.isEmpty || text.contains("@") { return nil }

        let (base, phoneExtension) = splitExtension(text)
        var digits = ""
        var hasPlus = false
        for character in base {
            if let digit = character.wholeNumberValue, (0...9).contains(digit), character.isNumber {
                digits.append(String(digit))
            } else if character == "+" && digits.isEmpty && !hasPlus {
                hasPlus = true
            } else if " ()[]-./\u{00A0}\u{2010}\u{2011}\u{2012}\u{2013}\u{2212}".contains(character) {
                continue
            } else if let mapped = keypadDigit(character), !digits.isEmpty || hasPlus {
                // Vanity numbers such as 1-800-FLOWERS, but never a word on its own.
                digits.append(mapped)
            } else {
                return nil
            }
        }
        guard !digits.isEmpty, digits.count <= 17 else { return nil }

        if hasPlus {
            return international(digits: digits, phoneExtension: phoneExtension)
        }
        // Outside North America, numbers without a country code follow each region's own
        // rules for prefixes and lengths, which libphonenumber's metadata knows.
        if let region = region?.uppercased(), let info = PhoneRegions.byRegion[region], info.code != "1" {
            let parsed = PhoneMetadata.parse(digits, region: region)
            // Six digits or fewer are a short code, unless they are a whole number: one
            // dialled with the region's trunk prefix, or, where there is none, as in the
            // Faroe Islands, one that the region's numbering allows.
            if digits.count <= 6, info.trunk.map({ !digits.hasPrefix($0) }) ?? (parsed == nil) {
                return PhoneNumber(normalized: digits, countryCode: nil, nationalNumber: digits, phoneExtension: phoneExtension)
            }
            if let (code, e164) = parsed, e164.count > code.count + 4 {
                return PhoneNumber(normalized: e164, countryCode: code, nationalNumber: String(e164.dropFirst(1 + code.count)), phoneExtension: phoneExtension)
            }
        }
        if let exitCode = region.flatMap({ PhoneRegions.exitCodes[$0.uppercased()] }), digits.hasPrefix(exitCode), digits.count > exitCode.count + 6 {
            return international(digits: String(digits.dropFirst(exitCode.count)), phoneExtension: phoneExtension)
        }
        if digits.hasPrefix("00"), digits.count > 8 {
            return international(digits: String(digits.dropFirst(2)), phoneExtension: phoneExtension)
        }
        if digits.hasPrefix("011"), digits.count > 9, region.map(PhoneRegions.isNANP) ?? true {
            return international(digits: String(digits.dropFirst(3)), phoneExtension: phoneExtension)
        }
        if let region = region?.uppercased(), let info = PhoneRegions.byRegion[region] {
            return national(digits: digits, region: info, phoneExtension: phoneExtension)
        }
        return PhoneNumber(normalized: digits, countryCode: nil, nationalNumber: digits, phoneExtension: phoneExtension)
    }

    /// Digits someone would have saved for this number without its country code: the
    /// national number, and the national number after the country's trunk prefix (the `0`
    /// in `020 7946 0000`). Empty when the country is unknown.
    public var nationalForms: [String] {
        guard let countryCode else { return [] }
        let trunk = PhoneRegions.trunkByCallingCode[countryCode] ?? nil
        return [nationalNumber] + (trunk.map { [$0 + nationalNumber] } ?? [])
    }

    /// True when both numbers certainly denote the same line. Numbers with different country
    /// codes never match. A number without a country code (7 digits or more) matches one with
    /// a country code when it is one of that number's `nationalForms`, so `020 7946 0000`
    /// matches London's `+44 20 7946 0000` but not Maine's `+1 207 946 0000`.
    public func matches(_ other: PhoneNumber) -> Bool {
        switch (countryCode, other.countryCode) {
        case (let lhs?, let rhs?):
            return lhs == rhs && nationalNumber == other.nationalNumber
        case (_?, nil):
            return other.nationalNumber.count >= 7 && nationalForms.contains(other.nationalNumber)
        case (nil, _?):
            return nationalNumber.count >= 7 && other.nationalForms.contains(nationalNumber)
        case (nil, nil):
            return normalized == other.normalized
        }
    }

    /// True when both are the same entry on a contact card: the same line and the same
    /// extension. Removing `+1 415 555 0100 x23` from a card leaves `+1 415 555 0100`.
    public func isSameEntry(_ other: PhoneNumber) -> Bool {
        matches(other) && phoneExtension == other.phoneExtension
    }

    // MARK: Parsing helpers

    /// `input` as plain characters: full-width digits and signs, as Japanese and Chinese
    /// input methods type them, become ASCII, and invisible formatting such as the direction
    /// marks phones put around numbers is dropped.
    static func plainCharacters(_ input: String) -> String {
        let folded = input.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? input
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { $0.properties.generalCategory != .format }))
    }

    private static func international(digits: String, phoneExtension: String?) -> PhoneNumber? {
        guard let code = PhoneRegions.callingCode(prefixOf: digits) else {
            return PhoneNumber(normalized: "+" + digits, countryCode: nil, nationalNumber: digits, phoneExtension: phoneExtension)
        }
        var national = String(digits.dropFirst(code.count))
        // Some people write the trunk zero after the country code: +44 (0)20 … Where a
        // country has no trunk prefix, a leading zero is part of the number (+39 06, +225 07).
        if PhoneRegions.trunkByCallingCode[code] == "0", national.hasPrefix("0"), national.count > 6 { national.removeFirst() }
        guard national.count >= 4 else { return nil }
        return PhoneNumber(normalized: "+" + code + national, countryCode: code, nationalNumber: national, phoneExtension: phoneExtension)
    }

    private static func national(digits: String, region: PhoneRegions.Info, phoneExtension: String?) -> PhoneNumber? {
        var national = digits
        if region.code == "1" {
            if national.count == 11, national.hasPrefix("1") { national.removeFirst() }
            // North American area codes start with 2-9; `0412 345 678` is from elsewhere.
            guard national.count == 10, let first = national.first, first != "0", first != "1" else {
                return PhoneNumber(normalized: digits, countryCode: nil, nationalNumber: digits, phoneExtension: phoneExtension)
            }
        } else {
            let longest = PhoneRegions.longestNationalNumber[region.code] ?? region.code.count + 6
            if national.hasPrefix(region.code), national.count > longest,
                region.trunk.map({ !national.hasPrefix($0) }) ?? true
            {
                // Written with the country code but without "+".
                national = String(national.dropFirst(region.code.count))
            } else if let trunk = region.trunk, national.hasPrefix(trunk) {
                national = String(national.dropFirst(trunk.count))
            }
            guard national.count >= 6 else {
                return PhoneNumber(normalized: digits, countryCode: nil, nationalNumber: digits, phoneExtension: phoneExtension)
            }
        }
        return PhoneNumber(normalized: "+" + region.code + national, countryCode: region.code, nationalNumber: national, phoneExtension: phoneExtension)
    }

    private static func splitExtension(_ text: String) -> (String, String?) {
        // `,` and `;` are the pauses and waits iPhone dials before an extension.
        let pattern = #"(?i)^(.*?)\s*(?:;ext=|ext\.?|extension|x|#|[,;]+)\s*([0-9]{1,8})\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let baseRange = Range(match.range(at: 1), in: text),
            let extensionRange = Range(match.range(at: 2), in: text),
            text[baseRange].contains(where: \.isNumber)
        else {
            return (text, nil)
        }
        return (String(text[baseRange]), String(text[extensionRange]))
    }

    private static func keypadDigit(_ character: Character) -> String? {
        guard let ascii = character.uppercased().first?.asciiValue, (65...90).contains(ascii) else { return nil }
        let map: [UInt8: String] = [
            65: "2", 66: "2", 67: "2", 68: "3", 69: "3", 70: "3", 71: "4", 72: "4", 73: "4",
            74: "5", 75: "5", 76: "5", 77: "6", 78: "6", 79: "6", 80: "7", 81: "7", 82: "7", 83: "7",
            84: "8", 85: "8", 86: "8", 87: "9", 88: "9", 89: "9", 90: "9",
        ]
        return map[ascii]
    }
}

/// Calling codes and trunk prefixes by ISO 3166 region.
public enum PhoneRegions {
    public struct Info: Sendable {
        public let region: String
        public let code: String
        /// Digits dialled before a national number inside the country, when they are not part
        /// of the number itself.
        public let trunk: String?
    }

    public static func isNANP(_ region: String) -> Bool {
        byRegion[region.uppercased()]?.code == "1"
    }

    /// The region from the system locale, used when a number has no country code.
    public static var systemRegion: String? {
        Locale.current.region?.identifier.uppercased()
    }

    /// The calling code that `digits` starts with. Codes are prefix-free, so at most one matches.
    static func callingCode(prefixOf digits: String) -> String? {
        for length in 1...3 where digits.count > length {
            let prefix = String(digits.prefix(length))
            if callingCodes.contains(prefix) { return prefix }
        }
        return nil
    }

    // Region:code:trunk. Trunk "-" means none: the national number keeps its leading digits
    // (Italy's landline zero) or the country does not use one.
    private static let table = """
        US:1:1 CA:1:1 AG:1:1 AI:1:1 AS:1:1 BB:1:1 BM:1:1 BS:1:1 DM:1:1 DO:1:1 GD:1:1 GU:1:1 JM:1:1 KN:1:1 KY:1:1 \
        LC:1:1 MP:1:1 MS:1:1 PR:1:1 SX:1:1 TC:1:1 TT:1:1 VC:1:1 VG:1:1 VI:1:1 \
        RU:7:8 KZ:7:8 EG:20:0 ZA:27:0 GR:30:- NL:31:0 BE:32:0 FR:33:0 ES:34:- HU:36:06 IT:39:- RO:40:0 CH:41:0 \
        AT:43:0 GB:44:0 GG:44:0 IM:44:0 JE:44:0 DK:45:- SE:46:0 NO:47:- PL:48:- DE:49:0 PE:51:0 MX:52:- CU:53:0 \
        AR:54:0 BR:55:0 CL:56:- CO:57:0 VE:58:0 MY:60:0 AU:61:0 ID:62:0 PH:63:0 NZ:64:0 SG:65:- TH:66:0 JP:81:0 \
        KR:82:0 VN:84:0 CN:86:0 TR:90:0 IN:91:0 PK:92:0 AF:93:0 LK:94:0 MM:95:0 IR:98:0 SS:211:0 MA:212:0 DZ:213:0 \
        TN:216:- LY:218:0 GM:220:- SN:221:- MR:222:- ML:223:- GN:224:- CI:225:- BF:226:- NE:227:- TG:228:- BJ:229:- \
        MU:230:- LR:231:0 SL:232:0 GH:233:0 NG:234:0 TD:235:- CF:236:- CM:237:- CV:238:- ST:239:- GQ:240:- GA:241:- \
        CG:242:- CD:243:0 AO:244:- GW:245:- SC:248:- SD:249:0 RW:250:0 ET:251:0 SO:252:0 DJ:253:- KE:254:0 TZ:255:0 \
        UG:256:0 BI:257:- MZ:258:- ZM:260:0 MG:261:0 RE:262:0 YT:262:0 ZW:263:0 NA:264:0 MW:265:0 LS:266:- BW:267:- \
        SZ:268:- KM:269:- SH:290:- ER:291:0 AW:297:- FO:298:- GL:299:- GI:350:- PT:351:- LU:352:- IE:353:0 IS:354:- \
        AL:355:0 MT:356:- CY:357:- FI:358:0 AX:358:0 BG:359:0 LT:370:0 LV:371:- EE:372:- MD:373:0 AM:374:0 BY:375:8 \
        AD:376:- MC:377:- SM:378:- VA:379:- UA:380:0 RS:381:0 ME:382:0 XK:383:0 HR:385:0 SI:386:0 BA:387:0 MK:389:0 \
        CZ:420:- SK:421:0 LI:423:- FK:500:- BZ:501:- GT:502:- SV:503:- HN:504:- NI:505:- CR:506:- PA:507:- PM:508:0 \
        HT:509:- GP:590:0 BL:590:0 MF:590:0 BO:591:0 GY:592:- EC:593:0 GF:594:0 PY:595:0 MQ:596:0 SR:597:- UY:598:0 \
        CW:599:- BQ:599:- TL:670:- NF:672:- BN:673:- NR:674:- PG:675:- TO:676:- SB:677:- VU:678:- FJ:679:- PW:680:- \
        WF:681:- CK:682:- NU:683:- WS:685:- KI:686:- NC:687:- TV:688:- PF:689:- TK:690:- FM:691:- MH:692:- KP:850:0 \
        HK:852:- MO:853:- KH:855:0 LA:856:0 BD:880:0 TW:886:0 MV:960:- LB:961:0 JO:962:0 SY:963:0 IQ:964:0 KW:965:- \
        SA:966:0 YE:967:0 OM:968:- PS:970:0 AE:971:0 IL:972:0 BH:973:- QA:974:- BT:975:- MN:976:0 NP:977:0 TJ:992:8 \
        TM:993:8 AZ:994:0 GE:995:0 KG:996:0 UZ:998:8
        """

    /// International call prefixes that differ from `00` (and North America's `011`), which
    /// `00` alone would misread: Australia's `0011 44…` is not `+1 144…`.
    static let exitCodes: [String: String] = ["AU": "0011", "JP": "010"]

    /// Trunk prefix by calling code. Regions sharing a calling code share a trunk prefix.
    static let trunkByCallingCode: [String: String?] = {
        var result: [String: String?] = [:]
        for info in byRegion.values { result[info.code] = info.trunk }
        return result
    }()

    /// Longest national number where national numbers can begin with the calling code
    /// (Kazakh 7xx, Italian 39x mobiles, the Polish area code 48). Longer digits start with
    /// the calling code; shorter ones are national. Elsewhere, 7 digits after the calling
    /// code mark it as written without `+`.
    static let longestNationalNumber: [String: Int] = ["7": 10, "39": 11, "48": 9]

    public static let byRegion: [String: Info] = {
        var result: [String: Info] = [:]
        for entry in table.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            let parts = entry.split(separator: ":").map(String.init)
            guard parts.count == 3 else { continue }
            result[parts[0]] = Info(region: parts[0], code: parts[1], trunk: parts[2] == "-" ? nil : parts[2])
        }
        return result
    }()

    static let callingCodes: Set<String> = Set(byRegion.values.map(\.code))
}
