package relay.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Themed character name collections used to auto-name new sessions.
 *
 * Ports `SessionNamingTheme` from `SessionNaming.swift` (ClaudeRelayClient).
 * Shared between iOS and Mac so both platforms pick from the same pools; this
 * Android port keeps the same six themes and verbatim name pools for parity.
 *
 * The [rawValue]s are stable camelCase identifiers suitable for persistence —
 * they match the Swift enum's (implicit) case-name raw values so a value
 * persisted via Swift `@AppStorage` round-trips unchanged. Each case is pinned
 * with [SerialName] so kotlinx-serialization emits the camelCase raw rather than
 * the Kotlin SCREAMING_SNAKE constant name. Don't rename a case without also
 * providing a migration.
 */
@Serializable
enum class SessionNamingTheme(val rawValue: String) {
    @SerialName("gameOfThrones")
    GAME_OF_THRONES("gameOfThrones"),

    @SerialName("viking")
    VIKING("viking"),

    @SerialName("starWars")
    STAR_WARS("starWars"),

    @SerialName("dune")
    DUNE("dune"),

    @SerialName("lordOfTheRings")
    LORD_OF_THE_RINGS("lordOfTheRings"),

    @SerialName("starTrek")
    STAR_TREK("starTrek");

    /** Human-readable label, matching `SessionNamingTheme.displayName` in Swift. */
    val displayName: String
        get() = when (this) {
            GAME_OF_THRONES -> "Game of Thrones"
            VIKING -> "Viking"
            STAR_WARS -> "Star Wars"
            DUNE -> "Dune"
            LORD_OF_THE_RINGS -> "Lord of the Rings"
            STAR_TREK -> "Star Trek"
        }

    /** The per-theme name pool drawn from when auto-naming a session. */
    val names: List<String>
        get() = when (this) {
            GAME_OF_THRONES -> GOT_NAMES
            VIKING -> VIKING_NAMES
            STAR_WARS -> STAR_WARS_NAMES
            DUNE -> DUNE_NAMES
            LORD_OF_THE_RINGS -> LOTR_NAMES
            STAR_TREK -> STAR_TREK_NAMES
        }

    companion object {
        /** Default theme, matching the Swift default (`gameOfThrones`). */
        val DEFAULT = GAME_OF_THRONES

        /** Resolves a persisted [rawValue]; falls back to [DEFAULT] on unknown. */
        fun fromRaw(raw: String): SessionNamingTheme =
            entries.firstOrNull { it.rawValue == raw } ?: DEFAULT

        // Ported verbatim from SessionNaming.swift (same names, same order).

        val GOT_NAMES = listOf(
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
        )

        val VIKING_NAMES = listOf(
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
        )

        val STAR_WARS_NAMES = listOf(
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
        )

        val DUNE_NAMES = listOf(
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
        )

        val LOTR_NAMES = listOf(
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
        )

        val STAR_TREK_NAMES = listOf(
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
        )
    }
}
