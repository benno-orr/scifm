import Foundation

enum ScientificPronunciation {

    // Apply all pronunciation rewrites to text before it goes to TTS
    static func rewrite(_ text: String) -> String {
        var result = text

        // Literal substitutions (order matters: longer/more specific first)
        for (pattern, replacement) in substitutions {
            result = result.replacingOccurrences(
                of: pattern, with: replacement, options: .regularExpression
            )
        }

        // Interleukin numbers: IL-6 → "interleukin 6", IL-10 → "interleukin 10"
        if let re = try? NSRegularExpression(pattern: "\\bIL-(\\d+)\\b") {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = re.stringByReplacingMatches(in: result, range: range, withTemplate: "interleukin $1")
        }

        return result
    }

    // (pattern, replacement) — plain NSRegularExpression patterns, no backreferences
    private static let substitutions: [(String, String)] = [

        // ── RNA subtypes (before plain RNA) ──
        ("\\bmRNA\\b",      "M R N Ay"),
        ("\\bsiRNA\\b",     "S I R N A"),
        ("\\bshRNA\\b",     "S H R N A"),
        ("\\bmiRNA\\b",     "micro R N A"),
        ("\\blncRNA\\b",    "link R N A"),
        ("\\bsnRNA\\b",     "S N R N A"),
        ("\\brRNA\\b",      "ribosomal R N A"),
        ("\\btRNA\\b",      "transfer R N A"),
        ("\\bsgRNA\\b",     "S G R N A"),
        ("\\bcrRNA\\b",     "C R R N A"),
        ("\\btracrRNA\\b",  "tracker R N A"),
        ("\\bRNA-seq\\b",   "R N A seek"),
        ("\\bscRNA-seq\\b", "single cell R N A seek"),
        ("\\bRNA\\b",       "R N A"),

        // ── DNA subtypes (before plain DNA) ──
        ("\\bcDNA\\b",  "C D N A"),
        ("\\bgDNA\\b",  "G D N A"),
        ("\\bctDNA\\b", "C T D N A"),
        ("\\bcfDNA\\b", "C F D N A"),
        ("\\bDNA\\b",   "D N A"),

        // ── Sequencing assays ──
        ("\\bChIP-seq\\b",  "chip seek"),
        ("\\bATAC-seq\\b",  "A tack seek"),
        ("\\bCUT&RUN\\b",   "cut and run"),
        ("\\bHi-C\\b",      "Hi C"),
        ("\\bChIP\\b",      "chip"),
        ("\\bCHIP\\b",      "chip"),

        // ── PCR ──
        ("\\bRT-PCR\\b", "R T P C R"),
        ("\\bqPCR\\b",   "Q P C R"),
        ("\\bPCR\\b",    "P C R"),

        // ── Gene editing ──
        ("\\bCRISPR\\b", "crisper"),
        ("\\bdCas9\\b",  "D Cas 9"),
        ("\\bCas9\\b",   "Cas 9"),
        ("\\bCas12\\b",  "Cas 12"),

        // ── Signaling pathways ──
        ("\\bJAK-STAT\\b", "jack stat"),
        ("\\bJAK\\b",      "jack"),
        ("\\bSTAT\\b",     "stat"),
        ("\\bBCR-ABL\\b",  "BCR able"),
        ("\\bABL\\b",      "able"),
        ("\\bMAPK\\b",     "map kinase"),
        ("\\bPI3K\\b",     "P I 3 K"),
        ("\\bmTOR\\b",     "em tor"),
        ("\\bNF-κB\\b",    "N F kappa B"),
        ("\\bNF-kB\\b",    "N F kappa B"),
        ("\\bERK\\b",      "E R K"),
        ("\\bAKT\\b",      "akt"),

        // ── Receptors / growth factors ──
        ("\\bEGFR\\b", "E G F R"),
        ("\\bEGF\\b",  "E G F"),
        ("\\bVEGFR\\b","V E G F R"),
        ("\\bVEGF\\b", "V E G F"),
        ("\\bHER2\\b", "H E R 2"),
        ("\\bHER3\\b", "H E R 3"),
        ("\\bHER4\\b", "H E R 4"),
        ("\\bTNF\\b",  "T N F"),
        ("\\bIFN\\b",  "I F N"),
        ("\\bTGF\\b",  "T G F"),

        // ── Tumor suppressors / oncogenes ──
        ("\\bBRCA1\\b", "B R C A 1"),
        ("\\bBRCA2\\b", "B R C A 2"),
        ("\\bBRCA\\b",  "B R C A"),
        ("\\bp53\\b",   "P 53"),
        ("\\bp21\\b",   "P 21"),
        ("\\bp16\\b",   "P 16"),

        // ── Energy / metabolites ──
        ("\\bNADPH\\b", "N A D P H"),
        ("\\bNADH\\b",  "N A D H"),
        ("\\bATP\\b",   "A T P"),
        ("\\bADP\\b",   "A D P"),
        ("\\bGTP\\b",   "G T P"),

        // ── Genetics / genomics ──
        ("\\bGWAS\\b",  "gwas"),
        ("\\bSNPs\\b",  "snips"),
        ("\\bSNP\\b",   "snip"),
        ("\\bQTL\\b",   "Q T L"),
        ("\\beQTL\\b",  "E Q T L"),
        ("\\bWGS\\b",   "W G S"),
        ("\\bWES\\b",   "W E S"),

        // ── Other ──
        ("\\bpH\\b",    "P H"),
        ("\\bBCR\\b",   "B C R"),
    ]
}
