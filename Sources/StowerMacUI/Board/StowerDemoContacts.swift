import Foundation

#if DEBUG
    /// Fake handle→name entries for the demo Messages database, so the board shows
    /// real-looking names instead of the 555-01xx demo numbers — WITHOUT writing
    /// anything to the real address book or prompting for Contacts access.
    ///
    /// DEBUG-only. In demo mode (`STOWER_MESSAGES_DB` set) `StowerMessagesComposition`
    /// builds an in-memory `StowerContactsResolver(mapping:)` from this table and
    /// injects it into the board, so names resolve instantly (no `.live()` address-book
    /// enumeration, no permission prompt). It touches none of the production contact
    /// resolution path.
    ///
    /// The handle scheme MUST match `Scripts/generate-demo-db.py` (`+1415555<0100+i>`,
    /// one per thread). Names are arbitrary — thread text never references them — so
    /// this list and the generator evolve independently as long as the handle formula
    /// and thread count agree.
    internal enum StowerDemoContacts {
        /// Handle-to-name entries for every demo thread, keyed as the generator writes them.
        internal static let mapping: [String: String] = {
            var result: [String: String] = [:]
            for (index, name) in names.enumerated() {
                result[handle(index: index)] = name
            }
            return result
        }()

        /// The demo handle for thread `index`, matching the generator's numbering.
        private static func handle(index: Int) -> String {
            handlePrefix + String(format: handleFormat, firstLineNumber + index)
        }

        /// The shared area-code + exchange prefix every demo number carries.
        private static let handlePrefix = "+1415555"

        /// Zero-padded four-digit line number (`0100`, `0101`, …), matching the generator.
        private static let handleFormat = "%04d"

        /// The generator's first line-number suffix (`+14155550100`).
        private static let firstLineNumber = 100

        /// One display name per demo thread, in thread order: the first 15 land in
        /// "Your turn", the last 15 in "Maybe follow up".
        private static let names = [
            "Sarah Chen", "David Park", "Priya Patel", "Jordan Lee", "Emma Thompson",
            "Luis Garcia", "Aisha Khan", "Tom Nguyen", "Rachel Green", "Omar Haddad",
            "Sofia Rossi", "Ben Carter", "Mei Lin", "Jamal Wright", "Nina Kowalski",
            "Chris Bennett", "Hannah Cohen", "Diego Morales", "Yuki Tanaka", "Grace Okafor",
            "Sam Rivera", "Lena Fischer", "Raj Mehta", "Chloe Dubois", "Ethan Wells",
            "Isabel Cruz", "Noah Bergman", "Farah Aziz", "Leo Petrov", "Maya Anderson"
        ]
    }
#endif
