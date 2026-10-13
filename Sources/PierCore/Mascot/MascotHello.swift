import Foundation

/// Content and layout of `pier hello`: the gull plus a speech bubble. Pure (the random tip is passed in).
public enum MascotHello {
    public static let tips: [String] = [
        "`pier watch` is a live view: o opens a service, k kills it, enter shows details.",
        "`pier kill 3000` frees a stuck port (SIGTERM first, SIGKILL only if needed).",
        "`pier free 5173` prints the next free port starting from 5173.",
        "`pier qr shop` shows a QR code of the LAN URL, handy for testing on a phone.",
        "`pier stale` lists forgotten dev servers; `pier prune` stops them.",
        "`pier run` starts your package.json dev script with logs and restart built in.",
        "`pier expose shop` gives a service a public https URL via cloudflared.",
        "`pier mcp` lets Claude Code see and control your local services.",
        "`pier completions --install` adds <TAB> completion for ports and names.",
        "Targets are a port (exact) or a fuzzy name: `pier info next` finds your Next.js app.",
        "`pier url 3100 | pbcopy` puts a service URL on your clipboard.",
        "`pier ls --json | jq '.[].displayName'` turns the listing into data.",
        "`pier app install` adds the menu bar app.",
    ]

    public static let poseBlurbs: [MascotPose: String] = [
        .standing: "at ease", .sleeping: "nothing is listening", .celebrating: "something got cleaned up",
        .saluting: "reporting for duty", .waving: "the default greeting", .thinking: "pondering a port",
        .coffee: "idle servers, coffee break", .surprised: "well, that happened",
    ]

    public static func bubbleText(version: String, tip: String) -> [String] {
        ["Ahoy! I'm the pier gull. (pier \(version))", "", "Tip: \(tip)", "", Mascot.repoURL]
    }

    /// The whole greeting. Gull on the left and a speech bubble on the right when the terminal is wide enough
    /// (>= 70 columns: medium gull; >= 56: small gull); 40-55 columns stack the small gull above the text;
    /// narrower terminals (or `showMascot: false`) get just the text. The repo URL is never split.
    public static func lines(pose: MascotPose, version: String, tip: String, caps: TermCaps, showMascot: Bool) -> [String] {
        let text = bubbleText(version: version, tip: tip)
        let style = MascotStyle(caps: caps)
        let width = caps.width
        func plainText() -> [String] { text.flatMap { Mascot.wrap($0, width: max(20, width - 1), breakLongWords: false) } }
        guard showMascot, width >= Mascot.minTerminalWidth else { return plainText() }
        let urlBubble = Mascot.repoURL.count + 4
        let medium = Mascot.render(pose, .medium, style: style)
        let small = Mascot.render(pose, .small, style: style)
        func widthOf(_ a: [String]) -> Int { a.map { AnsiText.width($0) }.max() ?? 0 }
        let art: [String]
        if style.blocks, width >= widthOf(medium) + 2 + urlBubble { art = medium }
        else if width >= widthOf(small) + 2 + urlBubble { art = small }
        else { return small + [""] + plainText() }
        let artWidth = widthOf(art)
        let maxBubble = min(52, width - artWidth - 2)
        let widest = text.map { DisplayWidth.of($0) }.max() ?? 0
        let bubbleWidth = min(maxBubble, widest + 4)
        // The tail points at the beak: roughly 40% down the gull.
        let beakRow = Int((Double(art.count) * 0.4).rounded())
        var bubble = Mascot.bubble(text, width: bubbleWidth, unicode: style.unicode, pointer: 0)
        let tailIndex = bubble.count / 2
        bubble = Mascot.bubble(text, width: bubbleWidth, unicode: style.unicode, pointer: tailIndex - 1)
        let top = max(0, min(beakRow - tailIndex, max(0, art.count - bubble.count)))
        let padded = Array(repeating: "", count: top) + bubble
        let rows = max(art.count, padded.count)
        var out: [String] = []
        let spacer = "  "
        for r in 0..<rows {
            let a = r < art.count ? art[r] : String(repeating: " ", count: artWidth)
            let b = r < padded.count ? padded[r] : ""
            out.append(a + (b.isEmpty ? "" : spacer + b))
        }
        return out
    }
}
