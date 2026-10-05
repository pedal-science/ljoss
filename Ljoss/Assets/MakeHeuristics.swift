import Foundation

/// What brand a model or impulse response is by.
///
/// "Make" is brand or manufacturer — Fender, Marshall, Celestion — and almost nothing
/// in a NAM library declares it. The reference format has a `metadata.gear_make`, and
/// a capture made by a stranger with an empty metadata block has nothing at all, which
/// is the common case for a folder of files someone else collected.
///
/// So this is a **table, not magic**: the file's own claim when it makes one, a word
/// match against the names captures actually use otherwise, and `Unknown` — a real
/// answer that groups and sorts like any other — when neither does.
enum MakeHeuristics {

    /// What a file is filed under when nothing about it names a brand. Sorted last, so
    /// the bucket nobody wants is never at the top of the list.
    static let unknown = "Unknown"

    /// One canonical brand and the spellings seen in capture filenames. The names on
    /// the right are what people type: `ORNG-V30-e609`, `MRSH 1960A`, `V30 SM57`.
    ///
    /// Speaker and microphone names appear under their own maker because that is what a
    /// cabinet IR is usually named after, and grouping a folder of them by "V30" and
    /// "SM57" would be grouping by model, which is not a brand.
    private static let brands: [(name: String, spellings: [String])] = [
        ("Fender", ["fender", "fndr"]),
        ("Marshall", ["marshall", "mrsh"]),
        ("Vox", ["vox"]),
        ("Mesa/Boogie", ["mesa boogie", "mesa", "boogie"]),
        ("Orange", ["orange", "orng"]),
        ("Ampeg", ["ampeg", "ampg"]),
        ("Peavey", ["peavey"]),
        ("Hiwatt", ["hiwatt"]),
        ("Friedman", ["friedman"]),
        ("Soldano", ["soldano"]),
        ("Bogner", ["bogner"]),
        ("Diezel", ["diezel"]),
        ("EVH", ["evh"]),
        ("PRS", ["prs", "paul reed smith"]),
        ("Matchless", ["matchless"]),
        ("Dumble", ["dumble"]),
        ("Supro", ["supro"]),
        ("Silvertone", ["silvertone"]),
        ("Gibson", ["gibson"]),
        ("Gretsch", ["gretsch"]),
        ("Rickenbacker", ["rickenbacker"]),
        ("Music Man", ["music man", "musicman"]),
        ("Roland", ["roland"]),
        ("Boss", ["boss"]),
        ("Line 6", ["line 6", "line6"]),
        ("Kemper", ["kemper"]),
        ("Neural DSP", ["neural dsp", "neural"]),
        ("ToneX", ["tonex", "tone x"]),
        ("Yamaha", ["yamaha"]),
        ("Darkglass", ["darkglass"]),
        ("Gallien-Krueger", ["gallien krueger", "gallien"]),
        ("Markbass", ["markbass", "mark bass"]),
        ("Aguilar", ["aguilar"]),
        ("Tech 21", ["tech 21", "tech21", "sansamp", "sans amp"]),
        ("Zvex", ["zvex"]),
        ("Fulltone", ["fulltone"]),
        ("Ibanez", ["ibanez"]),
        ("Celestion", ["celestion", "v30", "greenback", "creamback", "g12m", "g12h", "alnico"]),
        ("Jensen", ["jensen"]),
        ("Eminence", ["eminence"]),
        ("Scumback", ["scumback"]),
        ("Shure", ["shure", "sm57", "sm58", "sm7"]),
        ("Sennheiser", ["sennheiser", "md421", "e609", "e906"]),
        ("Royer", ["royer", "r121"]),
        ("Audix", ["audix"]),
        ("Neumann", ["neumann", "u87", "u47"]),
        ("AKG", ["akg"]),
        ("Beyerdynamic", ["beyerdynamic", "beyer dynamic", "m160"]),
        ("Electro-Voice", ["electro voice", "electrovoice", "re20"]),
        ("Heil", ["heil", "pr30"]),
        ("Rode", ["rode"]),
        ("Warm Audio", ["warm audio"]),
        ("Universal Audio", ["universal audio"]),
        ("Fractal", ["fractal"]),
        ("HeadRush", ["headrush"]),
    ]

    /// The brand for one file.
    ///
    /// - Parameters:
    ///   - claimed: `metadata.gear_make`, when the file had one.
    ///   - fileStem: the file's name without its extension.
    ///   - directories: the folder names between the root and the file, outermost first
    ///     — where a person who files captures by brand puts the brand.
    static func make(claimed: String?, fileStem: String, directories: [String]) -> String {
        if let claimed = claimed?.trimmingCharacters(in: .whitespacesAndNewlines), !claimed.isEmpty {
            // A file's own claim wins, but a claim like "Orange Rockerverb mk3" names
            // the amp as well as the brand, and "Orange" is what groups.
            return canonical(in: claimed) ?? claimed
        }
        // Deepest folder first: `Fender/deluxe.nam` is a Fender before "deluxe" is
        // anything at all, and a brand folder is a stronger signal than any one word of
        // a filename.
        for text in Array(directories.reversed()) + [fileStem] {
            if let brand = canonical(in: text) { return brand }
        }
        return unknown
    }

    /// The canonical brand a piece of text names, or nil.
    ///
    /// Matching is on whole words, so `orange` is Orange and `orangewood` is not, and it
    /// is longest-phrase-first, so `mesa boogie` beats `boogie` beats `mesa`.
    static func canonical(in text: String) -> String? {
        let words = Self.words(in: text)
        guard !words.isEmpty else { return nil }

        var best: (brand: String, length: Int)?
        for brand in brands {
            for spelling in brand.spellings {
                let phrase = Self.words(in: spelling)
                guard !phrase.isEmpty, phrase.count <= words.count else { continue }
                for start in 0...(words.count - phrase.count) where words[start..<(start + phrase.count)] == phrase[...] {
                    if phrase.count > (best?.length ?? 0) { best = (brand.name, phrase.count) }
                }
            }
        }
        return best?.brand
    }

    /// Lowercased alphanumeric words: punctuation, dashes and underscores are all just
    /// separators in a filename.
    private static func words(in text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
