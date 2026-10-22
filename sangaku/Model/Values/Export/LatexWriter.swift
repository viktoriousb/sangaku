import Foundation

/// The LaTeX export: one file that compiles on its own with pdfLaTeX. It holds the theorem and the statements it
/// uses, the steps of their proofs with who wrote and who checked each, each statement's status, the AI-use
/// statement and the notation's macros. Writers only join fragments; the text in them passed the gate.
nonisolated enum LatexWriter {
    /// The packages and environments the gate's allow-list is checked against.
    static let preamble: TeXFragment = #"""
        \documentclass[11pt]{amsart}
        \usepackage[T1]{fontenc}
        \usepackage{amssymb,mathtools,mathrsfs}
        \usepackage[hidelinks]{hyperref}
        \theoremstyle{plain}
        \newtheorem{theorem}{Theorem}
        \newtheorem{lemma}[theorem]{Lemma}
        \newtheorem{claim}[theorem]{Claim}
        \newtheorem{conjecture}[theorem]{Conjecture}
        \providecommand{\imported}[1]{\textnormal{\textsc{imported:} #1}}

        """# + itemMacros + "\n"

    /// The status paragraph and the step heading of an item, in both exports.
    static let itemMacros: TeXFragment = #"""
        \newcommand{\sgkstatus}[1]{\par\smallskip\noindent{\small\itshape #1\par}\smallskip}
        \newcommand{\sgkstep}[2]{\par\medskip\noindent\textbf{Step #1} (\emph{#2}).\enspace}

        """#

    static func write(_ document: ExportDocument) -> String {
        var out: [TeXFragment] = [
            "% Generated from the problem's record: its statements, the steps of their proofs, who wrote and who\n",
            "% checked each, and their statuses. Export again rather than editing by hand.\n",
            preamble,
        ]
        if !document.macros.isEmpty {
            out.append("% The problem's notation\n")
            out.append(TeXFragment.joined(document.macros, separator: "\n") + "\n")
        }
        out.append("\n\\begin{document}\n\\title{" + document.title + "}\n\\date{}\n\\maketitle\n\n")

        out.append("\\section*{Use of AI}\n")
        out.append(TeXFragment.joined(document.aiUse, separator: "\n\n") + "\n\n")

        if !document.notation.isEmpty {
            out.append("\\section*{Notation}\n\\begin{itemize}\n")
            for line in document.notation { out.append("\\item " + line.symbol + ": " + line.meaning + "\n") }
            out.append("\\end{itemize}\n\n")
        }

        out.append("\\section*{Statements}\n\n")
        for item in document.items { out.append(Self.item(item) + "\n") }

        out.append(statusTable(document.items))
        if !document.references.isEmpty {
            out.append("\n\\begin{thebibliography}{99}\n")
            for reference in document.references { out.append(Self.reference(reference) + "\n") }
            out.append("\\end{thebibliography}\n")
        }
        out.append("\n\\end{document}\n")
        return TeXFragment.joined(out).source
    }

    /// An item, its status, and its proof as recorded. The manuscript writes a refutation as an item of its own.
    static func item(_ item: ExportDocument.Item, refutation: Bool = true) -> TeXFragment {
        let name = item.environment.name
        var out: TeXFragment = "\\begin{" + name + "}[" + item.title + "]\\label{" + item.label + "}\n"
            + item.statement + "\n\\end{" + name + "}\n"
        out += "\\sgkstatus{" + TeXFragment.joined(item.status, separator: " ") + "}\n"
        if let uses = item.uses { out += uses + "\n" }
        if refutation, let text = item.refutation { out += "\\par\\noindent " + text + "\n" }
        if !item.proof.isEmpty { out += proof(item.proof) }
        return out
    }

    static func proof(_ parts: [ExportDocument.ProofPart]) -> TeXFragment {
        var out: TeXFragment = "\\begin{proof}[Proof, as recorded]\n"
        for part in parts {
            out += "\\textit{" + part.source + "}\n"
            for step in part.steps {
                out += "\\sgkstep{" + TeXFragment(step.number) + "}{" + step.establishes + "}" + step.text + "\n"
                out += "\\par{\\small\\itshape " + step.provenance + "\\par}\n"
                if !step.citations.isEmpty {
                    out += "{\\small Cites " + TeXFragment.joined(step.citations, separator: "; ") + ".\\par}\n"
                }
            }
        }
        return out + "\\end{proof}\n"
    }

    static func statusTable(_ items: [ExportDocument.Item]) -> TeXFragment {
        var out: TeXFragment = "\\section*{Status of the statements}\n\\begin{center}\n"
            + "\\begin{tabular}{p{0.2\\linewidth}p{0.2\\linewidth}p{0.45\\linewidth}}\n\\hline\n"
            + "Statement & Item & Status\\\\\n\\hline\n"
        for item in items {
            out += item.name + " & \\ref{" + item.label + "} & " + item.statusWords + "\\\\\n"
        }
        return out + "\\hline\n\\end{tabular}\n\\end{center}\n"
    }

    /// From what the index returned only; the link only for a found citation (invariant 6).
    static func reference(_ reference: ExportDocument.Reference) -> TeXFragment {
        var out: TeXFragment = "\\bibitem{" + reference.key + "} " + TeXFragment.joined(reference.authors, separator: ", ")
            + ", \\emph{" + reference.title + "}"
        if let year = reference.year { out += ", " + TeXFragment(year) }
        out += "."
        if let link = reference.link { out += " " + link + "." }
        return out + " Matched in " + reference.index + "."
    }
}
