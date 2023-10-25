//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#if canImport(FoundationEssentials)
import FoundationEssentials
#endif

#if canImport(Glibc)
import Glibc
#endif

#if canImport(ucrt)
import ucrt
#endif

#if canImport(FoundationICU)
#if FOUNDATION_FRAMEWORK
@_implementationOnly import FoundationICU
#else
package import FoundationICU
#endif

let MIN_TIMEZONE_UDATE = -2177452800000.0  // 1901-01-01 00:00:00 +0000
let MAX_TIMEZONE_UDATE = 4133980800000.0  // 2101-01-01 00:00:00 +0000

internal final class _TimeZoneICU: _TimeZoneProtocol, Sendable {
    init?(secondsFromGMT: Int) {
        fatalError("Unexpected init")
    }
    
    struct State {
        /// Access must be serialized
        private var _calendar: UnsafeMutablePointer<UCalendar?>?

        mutating func calendar(_ identifier: String) -> UnsafeMutablePointer<UCalendar?>? {
            // Use cached value
            if let _calendar { return _calendar }

            // Open the calendar (_TimeZone will close)
            var status = U_ZERO_ERROR
            let calendar : UnsafeMutablePointer<UCalendar?>? = Array(identifier.utf16).withUnsafeBufferPointer {
                let calendar = ucal_open($0.baseAddress, Int32($0.count), "", UCAL_DEFAULT, &status)
                if !status.isSuccess {
                    return nil
                } else {
                    return calendar
                }
            }

            // If we have a result, keep it around
            if let calendar {
                _calendar = calendar
            }

            return calendar
        }
    }

    let lock: LockedState<State>
    let name: String
    
    deinit {
        lock.withLock {
            guard let c = $0.calendar(identifier) else { return }
            ucal_close(c)
        }
    }

    required init?(identifier: String) {
        guard !identifier.isEmpty else {
            return nil
        }

        // Historically we've been respecting abbreviations like "GMT" and "GMT+8" even though the argument is supposed to be an identifier in the form of "America/Los_Angeles".
        var name = identifier
        if let offset = TimeZone.tryParseGMTName(name), let offsetName = TimeZone.nameForSecondsFromGMT(offset) {
            name = offsetName
        } else {
            guard Self.getCanonicalTimeZoneID(for: name) != nil else {
                return nil
            }
        }

        self.name = name
        lock = LockedState(initialState: State())
    }
    
    // MARK: -
    var identifier: String {
        self.name
    }
    
    var data: Data? {
        nil
    }

    func secondsFromGMT(for date: Date) -> Int {
        return lock.withLock {
            var udate = date.udate
            // make answers agree with nextDaylightSavingTimeTransitionAfterDate
            if udate < MIN_TIMEZONE_UDATE { udate = MIN_TIMEZONE_UDATE }
            if MAX_TIMEZONE_UDATE < udate { udate = MAX_TIMEZONE_UDATE }

            guard let c = $0.calendar(identifier) else {
                return 0
            }

            var status = U_ZERO_ERROR
            ucal_setMillis(c, udate, &status)
            let offset = (ucal_get(c, UCAL_ZONE_OFFSET, &status) + ucal_get(c, UCAL_DST_OFFSET, &status)) / 1000
            if status.isSuccess {
                return Int(offset)
            } else {
                return 0
            }
        }
    }

    func abbreviation(for date: Date) -> String? {
        let dst = daylightSavingTimeOffset(for: date) != 0.0
        return lock.withLock {
            guard let c = $0.calendar(identifier) else { return nil }
            return Self.timeZoneDisplayName(for: c, timeZoneName: identifier, localeName: Locale.current.identifier, isShort: true, isGeneric: false, isDaylight: dst)
        }
    }

    func isDaylightSavingTime(for date: Date) -> Bool {
        return daylightSavingTimeOffset(for: date) != 0.0
    }

    func daylightSavingTimeOffset(for date: Date) -> TimeInterval {
        lock.withLock {
            var udate = date.udate
            if udate < MIN_TIMEZONE_UDATE { udate = MIN_TIMEZONE_UDATE }
            if MAX_TIMEZONE_UDATE < udate { udate = MAX_TIMEZONE_UDATE }

            guard let c = $0.calendar(identifier) else { return 0.0 }
            var status = U_ZERO_ERROR
            ucal_setMillis(c, udate, &status)
            let offset = ucal_get(c, UCAL_DST_OFFSET, &status)
            if status.isSuccess {
                return TimeInterval(Double(offset) / 1000.0)
            } else {
                return 0.0
            }
        }
    }

    func nextDaylightSavingTimeTransition(after date: Date) -> Date? {
        lock.withLock {
            guard let c = $0.calendar(identifier) else { return nil }
            return Self.nextDaylightSavingTimeTransition(forLocked: c, startingAt: date, limit: Date(udate: MAX_TIMEZONE_UDATE))
        }
    }

    func localizedName(for style: TimeZone.NameStyle, locale: Locale?) -> String? {
        let locID = locale?.identifier ?? ""
        return lock.withLock {
            guard let c = $0.calendar(identifier) else { return nil }
            switch style {
            case .standard:
                return Self.timeZoneDisplayName(for: c, timeZoneName: identifier, localeName: locID, isShort: false, isGeneric: false, isDaylight: false)
            case .shortStandard:
                return Self.timeZoneDisplayName(for: c, timeZoneName: identifier, localeName: locID, isShort: true, isGeneric: false, isDaylight: false)
            case .daylightSaving:
                return Self.timeZoneDisplayName(for: c, timeZoneName: identifier, localeName: locID, isShort: false, isGeneric: false, isDaylight: true)
            case .shortDaylightSaving:
                return Self.timeZoneDisplayName(for: c, timeZoneName: identifier, localeName: locID, isShort: true, isGeneric: false, isDaylight: true)
            case .generic:
                return Self.timeZoneDisplayName(for: c, timeZoneName: identifier, localeName: locID, isShort: false, isGeneric: true, isDaylight: false)
            case .shortGeneric:
                return Self.timeZoneDisplayName(for: c, timeZoneName: identifier, localeName: locID, isShort: true, isGeneric: true, isDaylight: false)
            }
        }
    }

    static var timeZoneDataVersion: String {
        var status = U_ZERO_ERROR
        guard let version = ucal_getTZDataVersion(&status), status.isSuccess, let str = String(validatingUTF8: version) else {
            return ""
        }
        return str
    }

    // MARK: -

    /// The `calendar` argument is mutated by this function. It is the caller's responsibility to make sure that `UCalendar` is protected from concurrent access.
    internal static func nextDaylightSavingTimeTransition(forLocked calendar: UnsafeMutablePointer<UCalendar?>, startingAt: Date, limit: Date) -> Date? {
        let startingAtUDate = max(startingAt.udate, MIN_TIMEZONE_UDATE)
        let limitUDate = min(limit.udate, MAX_TIMEZONE_UDATE)

        if limitUDate < startingAtUDate {
            // no transitions searched for after the limit arg, or the max time (for performance)
            return nil
        }

        var status = U_ZERO_ERROR
        let origMillis = ucal_getMillis(calendar, &status)
        defer {
            // Reset the state of ucalendar
            ucal_setMillis(calendar, origMillis, &status)
        }

        ucal_setMillis(calendar, startingAtUDate, &status)
        var answer: UDate = 0.0
        let result = ucal_getTimeZoneTransitionDate(calendar, UCAL_TZ_TRANSITION_NEXT, &answer, &status)

        if result == 0 || !status.isSuccess || limitUDate < answer {
            return nil
        }

        return Date(udate: answer)
    }

    private static func timeZoneDisplayName(for calendar: UnsafeMutablePointer<UCalendar?>, timeZoneName: String, localeName: String, isShort: Bool, isGeneric: Bool, isDaylight: Bool) -> String? {

        if isGeneric {
            let timeZoneIdentifier = Array(timeZoneName.utf16)
            let result: String? = timeZoneIdentifier.withUnsafeBufferPointer {
                var status = U_ZERO_ERROR
                guard let df = udat_open(UDAT_NONE, UDAT_NONE, localeName, $0.baseAddress, Int32($0.count), nil, 0, &status) else {
                    return nil
                }

                guard status.isSuccess else {
                    return nil
                }

                defer { udat_close(df) }

                let pattern = "vvvv"
                let patternUTF16 = Array(pattern.utf16)
                return patternUTF16.withUnsafeBufferPointer {
                    udat_applyPattern(df, UBool.false, $0.baseAddress, Int32(isShort ? 1 : $0.count))

                    return _withResizingUCharBuffer { buffer, size, status in
                        udat_format(df, ucal_getNow(), buffer, size, nil, &status)
                    }
                }
            }

            return result
        } else {
            let type = isShort ? (isDaylight ? UCAL_SHORT_DST : UCAL_SHORT_STANDARD) : (isDaylight ? UCAL_DST : UCAL_STANDARD)
            return _withResizingUCharBuffer { buffer, size, status in
                ucal_getTimeZoneDisplayName(calendar, type, localeName, buffer, Int32(size), &status)
            }
        }
    }

    internal static func getCanonicalTimeZoneID(for identifier: String) -> String? {
        let timeZoneIdentifier = Array(identifier.utf16)
        let result: String? = timeZoneIdentifier.withUnsafeBufferPointer { identifier in
            return _withResizingUCharBuffer { buffer, size, status in
                var isSystemID: UBool = UBool.false
                let len = ucal_getCanonicalTimeZoneID(identifier.baseAddress, Int32(identifier.count), buffer, size, &isSystemID, &status)
                if status.isSuccess && isSystemID.boolValue {
                    return len
                } else {
                    return nil
                }
            }
        }
        return result
    }

    internal static func timeZoneNamesFromICU() -> [String] {
        let filteredTimeZoneNames = [
            "ACT",
            "AET",
            "AGT",
            "ART",
            "AST",
            "Africa/Asmera",
            "Africa/Timbuktu",
            "America/Argentina/ComodRivadavia",
            "America/Atka",
            "America/Buenos_Aires",
            "America/Catamarca",
            "America/Coral_Harbour",
            "America/Cordoba",
            "America/Ensenada",
            "America/Fort_Wayne",
            "America/Indianapolis",
            "America/Jujuy",
            "America/Knox_IN",
            "America/Louisville",
            "America/Mendoza",
            "America/Porto_Acre",
            "America/Rosario",
            "America/Virgin",
            "Asia/Ashkhabad",
            "Asia/Kolkata",
            "Asia/Chungking",
            "Asia/Dacca",
            "Asia/Istanbul",
            "Asia/Macao",
            "Asia/Riyadh87",
            "Asia/Riyadh88",
            "Asia/Riyadh89",
            "Asia/Saigon",
            "Asia/Tel_Aviv",
            "Asia/Thimbu",
            "Asia/Ujung_Pandang",
            "Asia/Ulan_Bator",
            "Atlantic/Faeroe",
            "Atlantic/Jan_Mayen",
            "Australia/ACT",
            "Australia/Canberra",
            "Australia/LHI",
            "Australia/NSW",
            "Australia/North",
            "Australia/Queensland",
            "Australia/South",
            "Australia/Tasmania",
            "Australia/Victoria",
            "Australia/West",
            "Australia/Yancowinna",
            "BET",
            "BST",
            "Brazil/Acre",
            "Brazil/DeNoronha",
            "Brazil/East",
            "Brazil/West",
            "CAT",
            "CET",
            "CNT",
            "CST",
            "CST6CDT",
            "CTT",
            "Chile/Continental",
            "Chile/EasterIsland",
            "Cuba",
            "EAT",
            "ECT",
            "EET",
            "EST",
            "EST5EDT",
            "Egypt",
            "Eire",
            "Europe/Belfast",
            "Europe/Nicosia",
            "Europe/Tiraspol",
            "Factory",
            "GB",
            "GB-Eire",
            "GMT+0",
            "GMT-0",
            "GMT0",
            "Greenwich",
            "HST",
            "Hongkong",
            "IET",
            "IST",
            "Iceland",
            "Iran",
            "Israel",
            "JST",
            "Jamaica",
            "Japan",
            "Kwajalein",
            "Libya",
            "MET",
            "MIT",
            "MST",
            "MST7MDT",
            "Mexico/BajaNorte",
            "Mexico/BajaSur",
            "Mexico/General",
            "NET",
            "NST",
            "NZ",
            "NZ-CHAT",
            "Navajo",
            "PLT",
            "PNT",
            "PRC",
            "PRT",
            "PST",
            "PST8PDT",
            "Pacific/Samoa",
            "Pacific/Yap",
            "Poland",
            "Portugal",
            "ROC",
            "ROK",
            "SST",
            "Singapore",
            "Turkey",
            "UCT",
            "UTC",
            "Universal",
            "VST",
            "W-SU",
            "WET",
            "Zulu"
        ]
        var result: [String] = []

        // Step 1: Gather data from ICU
        var status = U_ZERO_ERROR
        let enumeration = ucal_openTimeZones(&status)
        guard status.isSuccess else {
            return result
        }

        defer { uenum_close(enumeration) }

        var length: Int32 = 0
        repeat {
            guard let chars = uenum_unext(enumeration, &length, &status), status.isSuccess else {
                break
            }

            // Filter out empty strings
            guard length > 0 else {
                continue
            }

            guard let tz = String(_utf16: chars, count: Int(length)) else {
                continue
            }

            // Filter out things starting with these prefixes
            guard !(tz.starts(with: "US/") || tz.starts(with: "Etc/") || tz.starts(with: "Canada/") || tz.starts(with: "SystemV/") || tz.starts(with: "Mideast/")) else {
                continue
            }

            // Filter out anything matching this list
            // This is an O(n^2) operation, but the result of this call should be cached somewhere
            guard !filteredTimeZoneNames.contains(tz) else {
                continue
            }

            result.append(tz)
        } while true

        return result
    }
}
#endif //canImport(FoundationICU)

// MARK: -

var icuTZIdentifiers: [String] = {
    _TimeZoneICU.timeZoneNamesFromICU()
}()

@available(macOS 10.10, iOS 8.0, watchOS 2.0, tvOS 9.0, *)
extension TimeZone {
    /// Returns an array of strings listing the identifier of all the time zones known to the system.
    public static var knownTimeZoneIdentifiers : [String] {
        icuTZIdentifiers
    }

#if FOUNDATION_FRAMEWORK && canImport(FoundationICU)
    /// Returns the time zone data version.
    public static var timeZoneDataVersion : String {
        // At this time only available in Framework build because of dependency on ICU. When TimeZone sinks to FoundationEssentials, we can make this available everywhere as an extension on TimeZone from FoundationInternationalization.
        _TimeZoneICU.timeZoneDataVersion
    }
#endif
}
