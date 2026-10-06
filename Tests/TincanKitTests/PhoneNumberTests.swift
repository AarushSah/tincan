import Foundation
import PhoneNumberKit
import Testing

@testable import TincanKit

@Suite("Phone numbers")
struct PhoneNumberTests {
    @Test(
        "US formats normalize to E.164",
        arguments: [
            "(415) 555-0142", "415-555-0142", "415.555.0142", "1 415 555 0142", "+1 (415) 555-0142",
            "+14155550142", "tel:+1-415-555-0142", "011 1 415 555 0142", "001 415 555 0142",
        ])
    func unitedStates(_ input: String) throws {
        let number = try #require(PhoneNumber.parse(input, region: "US"))
        #expect(number.normalized == "+14155550142")
        #expect(number.countryCode == "1")
        #expect(number.nationalNumber == "4155550142")
    }

    @Test func nationalNumbersUseTheRegionAndDropTheTrunkPrefix() throws {
        #expect(PhoneNumber.parse("090-1234-5678", region: "JP")?.normalized == "+819012345678")
        #expect(PhoneNumber.parse("010-1234-5678", region: "KR")?.normalized == "+821012345678")
        #expect(PhoneNumber.parse("020 7946 0000", region: "GB")?.normalized == "+442079460000")
        #expect(PhoneNumber.parse("0412 345 678", region: "AU")?.normalized == "+61412345678")
        #expect(PhoneNumber.parse("8 912 345 67 89", region: "RU")?.normalized == "+79123456789")
    }

    @Test func italianLandlinesKeepTheirLeadingZero() {
        #expect(PhoneNumber.parse("06 1234 5678", region: "IT")?.normalized == "+390612345678")
        #expect(PhoneNumber.parse("+39 06 1234 5678", region: "US")?.normalized == "+390612345678")
    }

    @Test func aTrunkZeroWrittenAfterTheCountryCodeIsRemoved() {
        #expect(PhoneNumber.parse("+44 (0)20 7946 0000", region: nil)?.normalized == "+442079460000")
    }

    @Test(
        "A zero after the country code stays where it is part of the number",
        arguments: [
            ("+225 07 12 34 56 78", "+2250712345678"), // Côte d'Ivoire
            ("+242 06 123 4567", "+242061234567"), // Republic of the Congo
            ("+378 0549 123456", "+3780549123456"), // San Marino
        ])
    func zerosThatBelongToTheNumber(input: String, normalized: String) {
        #expect(PhoneNumber.parse(input, region: "US")?.normalized == normalized)
    }

    @Test(
        "National numbers that begin with their country code keep it",
        arguments: [
            ("393 123 4567", "IT", "+393931234567"), // Italian mobile
            ("39 393 123 4567", "IT", "+393931234567"),
            ("701 234 5678", "KZ", "+77012345678"), // Kazakh mobile
            ("7 701 234 5678", "KZ", "+77012345678"),
            ("48 123 45 67", "PL", "+48481234567"), // Radom landline
            ("48 48 123 45 67", "PL", "+48481234567"),
            ("45 12 34 56 78", "DK", "+4512345678"),
        ])
    func nationalNumbersStartingWithTheCountryCode(input: String, region: String, normalized: String) {
        #expect(PhoneNumber.parse(input, region: region)?.normalized == normalized)
    }

    @Test func tenDigitsStartingWithZeroOrOneAreNotNorthAmerican() throws {
        // An Australian mobile saved in its national format on a Mac set to the US.
        let number = try #require(PhoneNumber.parse("0412 345 678", region: "US"))
        #expect(number.countryCode == nil)
        #expect(number.normalized == "0412345678")
    }

    @Test func internationalNumbersIgnoreTheDefaultRegion() {
        #expect(PhoneNumber.parse("+81 90 1234 5678", region: "US")?.normalized == "+819012345678")
    }

    @Test func extensionsAreSeparated() throws {
        let number = try #require(PhoneNumber.parse("+1 415 555 0142 ext. 23", region: "US"))
        #expect(number.normalized == "+14155550142")
        #expect(number.phoneExtension == "23")
    }

    @Test("Pauses and waits dialled after a number are an extension", arguments: ["+1 415 555 0142,,23", "+1 415 555 0142;23", "+1 415 555 0142, 23"])
    func pausesAndWaits(input: String) throws {
        let number = try #require(PhoneNumber.parse(input, region: "US"))
        #expect(number.normalized == "+14155550142")
        #expect(number.phoneExtension == "23")
    }

    @Test(
        "Exit codes other than 00 and 011 lead to international numbers",
        arguments: [
            ("0011 44 20 7946 0000", "AU"), ("010 44 20 7946 0000", "JP"), ("00 44 20 7946 0000", "DE"), ("011 44 20 7946 0000", "US"),
        ])
    func exitCodes(input: String, region: String) {
        #expect(PhoneNumber.parse(input, region: region)?.normalized == "+442079460000")
    }

    @Test func vanityNumbersMapKeypadLetters() {
        #expect(PhoneNumber.parse("1-800-FLOWERS", region: "US")?.normalized == "+18003569377")
    }

    @Test func textThatIsNotANumberIsRejected() {
        #expect(PhoneNumber.parse("maya@example.com", region: "US") == nil)
        #expect(PhoneNumber.parse("Maya", region: "US") == nil)
        #expect(PhoneNumber.parse("", region: "US") == nil)
        #expect(PhoneNumber.parse("urn:biz:1234", region: "US") == nil)
    }

    @Test func shortCodesStayDigits() throws {
        let number = try #require(PhoneNumber.parse("262966", region: "US"))
        #expect(number.isShortCode)
        #expect(number.countryCode == nil)
        #expect(number.normalized == "262966")
    }

    @Test("Short codes stay digits in every region", arguments: ["GB", "DE", "FR", "IN", "AU", "BR", "IT", "JP"])
    func shortCodesStayDigitsEverywhere(region: String) throws {
        for code in ["262966", "88022", "7726"] {
            let number = try #require(PhoneNumber.parse(code, region: region))
            #expect(number.isShortCode, "\(code) in \(region): \(number.normalized)")
            #expect(number.normalized == code)
        }
    }

    @Test func sixDigitNumbersAreWholeWhereTheRegionHasThem() {
        // The Faroe Islands have six-digit numbers and no trunk prefix.
        #expect(PhoneNumber.parse("312345", region: "FO")?.normalized == "+298312345")
    }

    /// National numbers that begin with their own calling code, which tincan once took for
    /// the code written without `+`.
    @Test func nationalNumbersThatBeginWithTheCallingCodeKeepIt() {
        #expect(PhoneNumber.parse("91234 56789", region: "IN")?.normalized == "+919123456789")
        #expect(PhoneNumber.parse("+91 91234 56789", region: "US")?.normalized == "+919123456789")
        #expect(PhoneNumber.parse("91 91234 56789", region: "IN")?.normalized == "+919123456789")
        #expect(PhoneNumber.parse("(55) 99999-9999", region: "BR")?.normalized == "+5555999999999")
        #expect(PhoneNumber.parse("055 99999-9999", region: "BR")?.normalized == "+5555999999999")
    }

    @Test func eachRegionsInternationalPrefixesAreKnown() {
        // South Korea's carriers each have one; Japan uses 010; Australia 0011.
        #expect(PhoneNumber.parse("001 1 415 555 0142", region: "KR")?.normalized == "+14155550142")
        #expect(PhoneNumber.parse("00700 1 415 555 0142", region: "KR")?.normalized == "+14155550142")
        #expect(PhoneNumber.parse("010 1 415 555 0142", region: "JP")?.normalized == "+14155550142")
        #expect(PhoneNumber.parse("0011 44 20 7946 0000", region: "AU")?.normalized == "+442079460000")
        #expect(PhoneNumber.parse("00 44 20 7946 0000", region: "FR")?.normalized == "+442079460000")
        // Brazil's and Colombia's international prefixes name a carrier.
        #expect(PhoneNumber.parse("0021 1 415 555 0142", region: "BR")?.normalized == "+14155550142")
        #expect(PhoneNumber.parse("009 1 415 555 0142", region: "CO")?.normalized == "+14155550142")
    }

    @Test func fullWidthDigitsAndInvisibleMarksAreReadAsTyped() {
        #expect(PhoneNumber.parse("＋１ ４１５－５５５－０１４２", region: nil)?.normalized == "+14155550142")
        #expect(PhoneNumber.parse("０９０－１２３４－５６７８", region: "JP")?.normalized == "+819012345678")
        #expect(PhoneNumber.parse("\u{202A}+1 (415) 555-0142\u{202C}", region: nil)?.normalized == "+14155550142")
        #expect(PhoneNumber.parse("\u{200E}+44 20 7946 0000", region: "US")?.normalized == "+442079460000")
    }

    /// tincan embeds its own copy of PhoneNumberKit's metadata. After updating PhoneNumberKit,
    /// copy its Resources/PhoneNumberMetadata.json to Support/.
    @Test func theEmbeddedMetadataIsPhoneNumberKits() throws {
        let support = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Support/PhoneNumberMetadata.json")
        let vendored = try Data(contentsOf: support.standardizedFileURL)
        #expect(vendored == (try PhoneNumberUtility.defaultMetadataCallback()), "Copy PhoneNumberKit's PhoneNumberMetadata.json to Support/")
    }

    @Test func incompleteNumbersDoNotGainACountryCode() throws {
        let local = try #require(PhoneNumber.parse("555-0142", region: "US"))
        #expect(local.countryCode == nil)
        let full = try #require(PhoneNumber.parse("+14155550142", region: nil))
        #expect(!local.matches(full))
    }

    @Test func matchingComparesCountryAndNationalNumber() throws {
        let a = try #require(PhoneNumber.parse("+14155550142", region: nil))
        let b = try #require(PhoneNumber.parse("(415) 555-0142", region: "US"))
        let unknownRegion = try #require(PhoneNumber.parse("4155550142", region: nil))
        let otherCountry = try #require(PhoneNumber.parse("+444155550142", region: nil))
        #expect(a.matches(b))
        #expect(a.matches(unknownRegion))
        #expect(!a.matches(otherCountry))
    }

    @Test func aNumberWithoutACountryMatchesOnlyCountriesWhoseTrunkPrefixItCarries() throws {
        // 020 7946 0000 is London written the British way. Its last ten digits are also a
        // number in Maine, where nobody dials a leading zero.
        let saved = try #require(PhoneNumber.parse("020 7946 0000", region: "US"))
        #expect(saved.countryCode == nil)
        #expect(saved.matches(try #require(PhoneNumber.parse("+442079460000", region: nil))))
        #expect(!saved.matches(try #require(PhoneNumber.parse("+12079460000", region: nil))))
        // Russia dials 8 before national numbers.
        let moscow = try #require(PhoneNumber.parse("8 912 345-67-89", region: "US"))
        #expect(moscow.matches(try #require(PhoneNumber.parse("+79123456789", region: nil))))
    }
}
