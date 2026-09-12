import Foundation

/// Themed character name collections used to auto-name new sessions.
///
/// Shared between iOS and Mac so both platforms pick from the same pools.
/// Raw values are stable identifiers suitable for `@AppStorage` persistence —
/// don't rename a case without also providing a migration.
public enum SessionNamingTheme: String, CaseIterable, Identifiable, Sendable {
    // Implicit raw values (case-name strings) are identical to the previous
    // explicit literals, so existing `@AppStorage` values round-trip unchanged.
    case gameOfThrones
    case viking
    case starWars
    case dune
    case lordOfTheRings
    case starTrek

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gameOfThrones: return "Game of Thrones"
        case .viking:        return "Viking"
        case .starWars:      return "Star Wars"
        case .dune:          return "Dune"
        case .lordOfTheRings: return "Lord of the Rings"
        case .starTrek:      return "Star Trek"
        }
    }

    public var names: [String] {
        switch self {
        case .gameOfThrones:  return Self.gotNames
        case .viking:         return Self.vikingNames
        case .starWars:       return Self.starWarsNames
        case .dune:           return Self.duneNames
        case .lordOfTheRings: return Self.lotrNames
        case .starTrek:       return Self.starTrekNames
        }
    }

    public static let gotNames = [
        "Arya", "Tyrion", "Daenerys", "Jon Snow", "Cersei",
        "Sansa", "Bran", "Jaime", "Brienne", "Theon",
        "Samwell", "Jorah", "Davos", "Missandei", "Varys",
        "Tormund", "Podrick", "Gendry", "Bronn", "Sandor",
        "Melisandre", "Ygritte", "Oberyn", "Margaery", "Olenna",
        "Ramsay", "Stannis", "Robb", "Catelyn", "Ned",
        "Hodor", "Gilly", "Drogo", "Viserys", "Littlefinger",
        "Tywin", "Joffrey", "Tommen", "Myrcella", "Rickon",
        "Osha", "Shae", "Yara", "Euron", "Ellaria",
        "Grey Worm", "Barristan", "Jojen", "Meera", "Benjen",
        "Lyanna", "Rhaegar", "Aemon", "Qyburn", "Septa",
        "Ros", "Talisa", "Edmure", "Blackfish", "Walder Frey",
        "Loras", "Renly", "Robert", "Lancel", "Hot Pie",
        "Nymeria", "Ghost", "Drogon", "Rhaegal", "Viserion"
    ]

    public static let vikingNames = [
        "Ragnar", "Lagertha", "Bjorn", "Rollo", "Floki",
        "Ivar", "Ubbe", "Sigurd", "Hvitserk", "Aslaug",
        "Athelstan", "Helga", "Torvi", "Harald", "Halfdan",
        "Freydis", "Leif", "Erik", "Gunnar", "Sigrid",
        "Thorstein", "Ingrid", "Arne", "Astrid", "Brynhild",
        "Gudrun", "Hakon", "Knut", "Olaf", "Sven",
        "Thyra", "Ulf", "Viggo", "Ylva", "Idunn",
        "Fenrir", "Odin", "Thor", "Freya", "Tyr",
        "Heimdall", "Baldur", "Loki", "Skadi", "Njord",
        "Valkyrie", "Berserker", "Jarl", "Thane", "Skald",
        "Rune", "Saga", "Edda", "Volva", "Gorm",
        "Canute", "Sweyn", "Magnus", "Sigmund", "Bragi",
        "Eira", "Solveig", "Revna", "Hilda", "Torunn",
        "Vidar", "Hermod", "Ran", "Aegir", "Mimir"
    ]

    public static let starWarsNames = [
        "Luke", "Leia", "Han Solo", "Chewie", "Vader",
        "Obi-Wan", "Yoda", "Palpatine", "Anakin", "Padme",
        "Ahsoka", "Rex", "Mace Windu", "Qui-Gon", "Maul",
        "Dooku", "Grievous", "Tarkin", "Lando", "Boba Fett",
        "Jango", "Jabba", "Wedge", "Ackbar", "Mon Mothma",
        "Bail", "Poe", "Finn", "Rey", "Kylo Ren",
        "Hux", "Phasma", "Snoke", "Rose", "Maz Kanata",
        "Din Djarin", "Grogu", "Bo-Katan", "Cara Dune", "Greef",
        "Fennec", "Cad Bane", "Ventress", "Savage", "Satine",
        "Hera", "Kanan", "Ezra", "Sabine", "Zeb",
        "Chopper", "Thrawn", "Kallus", "Cassian", "Jyn Erso",
        "K-2SO", "Chirrut", "Baze", "Saw", "Galen",
        "Nien Nunb", "Biggs", "Porkins", "Lobot", "Bossk",
        "IG-88", "Dengar", "Zuckuss", "4-LOM", "Enfys Nest"
    ]

    public static let duneNames = [
        "Paul", "Chani", "Leto", "Jessica", "Stilgar",
        "Duncan", "Gurney", "Thufir", "Alia", "Irulan",
        "Feyd", "Baron", "Rabban", "Piter", "Shaddam",
        "Liet", "Harah", "Jamis", "Mohiam", "Mapes",
        "Idaho", "Ghanima", "Farad'n", "Wensicia", "Javid",
        "Tuek", "Fenring", "Margot", "Scytale", "Bijaz",
        "Edric", "Korba", "Lichna", "Otheym", "Shishakli",
        "Naib", "Siona", "Hwi Noree", "Moneo", "Malky",
        "Taraza", "Odrade", "Lucilla", "Bellonda", "Murbella",
        "Teg", "Sheeana", "Waff", "Logno", "Dama",
        "Erasmus", "Omnius", "Serena", "Vorian", "Norma",
        "Aurelius", "Xavier", "Iblis", "Raquella", "Valya",
        "Tula", "Dorotea", "Gilbertus", "Manford", "Draigo",
        "Talamanes", "Reverend", "Sayyadina", "Usul", "Muad'Dib"
    ]

    public static let lotrNames = [
        "Frodo", "Sam", "Gandalf", "Aragorn", "Legolas",
        "Gimli", "Boromir", "Merry", "Pippin", "Gollum",
        "Saruman", "Sauron", "Elrond", "Galadriel", "Arwen",
        "Eowyn", "Theoden", "Eomer", "Faramir", "Denethor",
        "Treebeard", "Tom Bombadil", "Goldberry", "Radagast", "Glorfindel",
        "Haldir", "Celeborn", "Thranduil", "Bilbo", "Thorin",
        "Balin", "Dwalin", "Fili", "Kili", "Bofur",
        "Bombur", "Bifur", "Oin", "Gloin", "Dori",
        "Nori", "Ori", "Beorn", "Bard", "Smaug",
        "Grima", "Shelob", "Gothmog", "Lurtz", "Ugluk",
        "Shagrat", "Gorbag", "Deagol", "Rosie", "Lobelia",
        "Hamfast", "Farmer Maggot", "Quickbeam", "Shadowfax", "Bill the Pony",
        "Witch-King", "Mouth of Sauron", "Gil-galad", "Isildur", "Elendil",
        "Cirdan", "Feanor", "Fingolfin", "Earendil", "Hurin"
    ]

    public static let starTrekNames = [
        "Kirk", "Spock", "McCoy", "Uhura", "Scotty",
        "Sulu", "Chekov", "Chapel", "Rand", "Sarek",
        "Khan", "Pike", "T'Pring", "Number One",
        "Picard", "Riker", "Data", "Worf", "La Forge",
        "Crusher", "Troi", "Wesley", "Guinan", "Q",
        "Ro Laren", "Pulaski", "Tasha Yar", "Barclay", "Lwaxana",
        "Sisko", "Kira", "Odo", "Bashir", "Dax",
        "O'Brien", "Quark", "Garak", "Rom", "Nog",
        "Jake", "Dukat", "Weyoun", "Martok", "Damar",
        "Ezri", "Janeway", "Chakotay", "Tuvok", "Paris",
        "Torres", "Kim", "Neelix", "Kes", "Seven",
        "The Doctor", "Archer", "T'Pol", "Trip", "Reed",
        "Mayweather", "Hoshi", "Phlox", "Burnham", "Saru",
        "Tilly", "Lorca", "Georgiou", "Stamets", "Una",
        "La'an", "M'Benga", "Ortegas", "Mariner", "Boimler",
        "Tendi", "Rutherford"
    ]
}

/// Utilities for picking session names from a theme.
public enum SessionNaming {

    /// Picks a name from the theme that isn't already in `usedNames`.
    /// Falls back to "Session <fallbackIndex>" if all theme names are taken.
    ///
    /// - Parameters:
    ///   - usedNames: Names currently in use (case-sensitive).
    ///   - theme: The theme whose name pool to draw from.
    ///   - fallbackIndex: Number used in the fallback label when the pool is exhausted.
    public static func pickDefaultName(
        usedNames: Set<String>,
        theme: SessionNamingTheme,
        fallbackIndex: Int
    ) -> String {
        let available = theme.names.filter { !usedNames.contains($0) }
        return available.randomElement() ?? "Session \(fallbackIndex)"
    }
}
