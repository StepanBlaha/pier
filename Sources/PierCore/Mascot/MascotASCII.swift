// Hand-drawn ASCII-only gull (no color, no Unicode): used when the terminal can't be trusted with
// half blocks (LANG=C, CJK locales, TERM=linux) or has no color at all (NO_COLOR, 'none' color level).
// Every line of one pose is padded to the same width so it can sit beside text.

enum MascotASCII {
    static let standing = [
        "    ,---.    ",
        "   /=====\\   ",
        "   '-----'   ",
        "  ( o  )>    ",
        " /(      )\\  ",
        "/ (______) \\ ",
        "    /\\  /\\   ",
        "   '-'  '-'  ",
    ]

    static let sleeping = [
        "        z Z  ",
        "    ,---. z  ",
        "   /=====\\   ",
        "   '-----'   ",
        "  ( -  )>    ",
        " /(      )\\  ",
        "(  \\____/  ) ",
        "  `-'  `-'   ",
    ]

    static let celebrating = [
        " \\  ,---.  / ",
        "  \\/=====\\/  ",
        "   '-----'   ",
        "  ( ^  )>    ",
        "  (      )   ",
        " /(______)\\  ",
        "   /'  '\\    ",
        "  '      '   ",
    ]

    static let waving = [
        "    ,---.  / ",
        "   /=====\\/  ",
        "   '-----'/  ",
        "  ( o  )>(   ",
        " /(      )   ",
        "/ (______)   ",
        "    /\\  /\\   ",
        "   '-'  '-'  ",
    ]

    static func art(for pose: MascotPose) -> [String] {
        switch pose {
        case .sleeping: return sleeping
        case .celebrating: return celebrating
        case .waving, .saluting: return waving
        default: return standing
        }
    }
}
