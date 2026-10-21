import Foundation

/// A problem's Lean module as the app writes it: a fixed header, then each statement's code in its own namespace in
/// dependency order. Lean compiles it; the app's own kernel check (`AxiomCheck.lean`) then reads the compiled module as
/// data and reports each statement's axioms, so nothing the module's code prints or does can stand in for that report.
nonisolated struct LeanModulePlan: Hashable, Sendable {
    nonisolated struct Region: Hashable, Sendable {
        let statementID: UUID
        let source: LeanSource
        /// The module lines holding the statement's code, from its `namespace` line to its `end` line.
        let span: ClosedRange<Int>
        /// The module line of the code's first line: line 1 of the source is this line.
        let firstSourceLine: Int

        var declaration: String { LeanNaming.declaration(for: statementID) }
    }

    /// What every module imports.
    static let imports = ["Mathlib"]
    /// Auto-bound implicits are off: a misspelt name must be an error, never a new variable that quietly changes the
    /// statement.
    static let options = ["set_option autoImplicit false", "set_option relaxedAutoImplicit false"]

    /// The modules this one imports; the kernel check refuses a compiled module that imports anything else.
    let imports: [String]
    let text: String
    let regions: [Region]

    var digest: TextDigest { TextDigest(of: text) }

    /// The module for these statements' code, in the order given (dependencies first). Tests without Mathlib pass
    /// other imports.
    init(_ entries: [(statementID: UUID, source: LeanSource)], imports: [String] = LeanModulePlan.imports) {
        var lines = imports.map { "import " + $0 } + Self.options
        var regions: [Region] = []
        for entry in entries {
            lines.append("")
            let namespace = LeanNaming.namespace(for: entry.statementID)
            let start = lines.count + 1
            lines.append("namespace " + namespace)
            let first = lines.count + 1
            lines.append(contentsOf: entry.source.text.components(separatedBy: "\n"))
            lines.append("end " + namespace)
            regions.append(Region(statementID: entry.statementID, source: entry.source, span: start...lines.count,
                                  firstSourceLine: first))
        }
        self.imports = imports
        text = lines.joined(separator: "\n") + "\n"
        self.regions = regions
    }

    func region(for statement: UUID) -> Region? { regions.first { $0.statementID == statement } }
}

/// One statement's part of a check, as the service read it. Made only by `LeanOutputReader` (and the fixture), so an
/// axiom result can come from nowhere but the app's own kernel check.
nonisolated struct LeanRegionOutcome: Hashable, Sendable {
    let statementID: UUID
    let source: LeanSource
    /// Lines counted in the statement's source; 0 for its `namespace` and `end` lines.
    let messages: [LeanMessage]
    let sorryLocations: [LeanLocation]
    let errorCount: Int
    let sorryCount: Int
    let axiomCheck: AxiomCheck

    fileprivate init(statementID: UUID, source: LeanSource, messages: [LeanMessage], sorryLocations: [LeanLocation],
                     errorCount: Int, sorryCount: Int, axiomCheck: AxiomCheck) {
        self.statementID = statementID
        self.source = source
        self.messages = messages
        self.sorryLocations = sorryLocations
        self.errorCount = errorCount
        self.sorryCount = sorryCount
        self.axiomCheck = axiomCheck
    }
}

/// A whole check as read: a part per statement, and what the module around them reported. A check whose module
/// reported an error, or printed lines that are not Lean's JSON, says nothing reliable about any statement.
nonisolated struct LeanModuleOutcome: Hashable, Sendable {
    let regions: [LeanRegionOutcome]
    /// Messages on the header or between statements, which belong to no statement.
    let moduleMessages: [LeanMessage]
    let unreadableLines: Int
    /// The kernel check ran and reported on every statement; without it no statement's axioms are known.
    let axiomsChecked: Bool

    var moduleErrors: [LeanMessage] { moduleMessages.filter { $0.severity != "information" && $0.severity != "warning" } }

    /// Every statement's part can be recorded.
    var isReadable: Bool { moduleErrors.isEmpty && unreadableLines == 0 }

    /// Some statement's code has an error, so Lean compiled nothing for the kernel check.
    var hasErrors: Bool { regions.contains { $0.errorCount > 0 } }

    fileprivate init(regions: [LeanRegionOutcome], moduleMessages: [LeanMessage], unreadableLines: Int,
                     axiomsChecked: Bool) {
        self.regions = regions
        self.moduleMessages = moduleMessages
        self.unreadableLines = unreadableLines
        self.axiomsChecked = axiomsChecked
    }

    func region(for statement: UUID) -> LeanRegionOutcome? { regions.first { $0.statementID == statement } }
}

/// Reads a check: Lean's `--json` messages from compiling the module, placed by line into each statement's code, and
/// the app's kernel check (`AxiomCheck.lean`), one JSON line per statement's declaration. A statement's axioms come only
/// from exactly one kernel-check line naming its own declaration as a theorem; without the kernel check's output, or
/// with any line of it unreadable, no statement's axioms are known.
nonisolated enum LeanOutputReader {
    private struct Wire: Decodable {
        struct Position: Decodable {
            var line: Int
            var column: Int
        }

        var pos: Position
        var endPos: Position?
        var severity: String
        var kind: String?
        var data: String
    }

    /// One line of the kernel check.
    private struct Axioms: Decodable {
        var declaration: String
        var kind: String
        var axioms: [String]
    }

    /// `axioms` is the kernel check's output, or nil when it did not run.
    static func read(stdout: String, axioms: String?, plan: LeanModulePlan) -> LeanModuleOutcome {
        var unreadable = 0
        var wires: [Wire] = []
        for line in lines(stdout) {
            if let wire = try? JSONDecoder().decode(Wire.self, from: Data(line.utf8)) {
                wires.append(wire)
            } else {
                unreadable += 1
            }
        }

        var moduleMessages: [LeanMessage] = []
        var inRegion: [UUID: [LeanMessage]] = [:]
        for wire in wires {
            let severity = ["error", "warning", "information"].contains(wire.severity) ? wire.severity : "error"
            if let region = plan.regions.first(where: { $0.span.contains(wire.pos.line) }) {
                let first = region.firstSourceLine
                let inCode = wire.pos.line >= first && wire.pos.line < region.span.upperBound
                inRegion[region.statementID, default: []].append(LeanMessage(
                    severity: severity, line: inCode ? wire.pos.line - first + 1 : 0, column: wire.pos.column,
                    text: wire.data, kind: wire.kind, endLine: wire.endPos.map { inCode ? $0.line - first + 1 : 0 },
                    endColumn: wire.endPos?.column))
            } else {
                moduleMessages.append(LeanMessage(severity: severity, line: 0, column: wire.pos.column, text: wire.data,
                                                  kind: wire.kind))
            }
        }

        let reports = axioms.flatMap(kernelReports)
        let declarations = Set(plan.regions.map(\.declaration))
        let axiomsChecked = reports.map { reports in
            declarations.allSatisfy { name in reports.filter { $0.declaration == name }.count == 1 }
        } ?? false

        let regions = plan.regions.map { region in
            let messages = inRegion[region.statementID] ?? []
            let tokens = LeanLexicon.sorries(in: region.source.text)
            let reported = messages.filter { $0.kind == "hasSorry" || $0.text.contains("declaration uses 'sorry'")
                || $0.text.contains("declaration uses `sorry`") }
            return LeanRegionOutcome(
                statementID: region.statementID, source: region.source, messages: messages,
                sorryLocations: tokens.isEmpty ? reported.map { LeanLocation(line: $0.line, column: $0.column) } : tokens,
                errorCount: messages.filter { $0.severity == "error" }.count,
                sorryCount: max(tokens.count, reported.count),
                axiomCheck: axiomsChecked ? axiomCheck(reports ?? [], declaration: region.declaration) : .notRun)
        }
        return LeanModuleOutcome(regions: regions, moduleMessages: moduleMessages, unreadableLines: unreadable,
                                 axiomsChecked: axiomsChecked)
    }

    /// Every line of the kernel check, or nil if any line is not one of its reports.
    private static func kernelReports(_ output: String) -> [Axioms]? {
        var reports: [Axioms] = []
        for line in lines(output) {
            guard let report = try? JSONDecoder().decode(Axioms.self, from: Data(line.utf8)) else { return nil }
            reports.append(report)
        }
        return reports
    }

    /// The axioms the kernel check reported for a statement's declaration, if it found it as a theorem.
    private static func axiomCheck(_ reports: [Axioms], declaration: String) -> AxiomCheck {
        let matching = reports.filter { $0.declaration == declaration }
        guard matching.count == 1, let report = matching.first, report.kind == "theorem",
              report.axioms.allSatisfy({ !$0.isEmpty && !$0.contains(where: \.isWhitespace) }) else { return .notRun }
        return .ran(declaration: declaration, axioms: report.axioms)
    }

    /// Non-empty lines, split at line feeds only: Lean's JSON may hold other line separators inside a string.
    private static func lines(_ text: String) -> [Substring] {
        text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

#if DEBUG
extension LeanRegionOutcome {
    /// A statement's check as the fixture records it, without running Lean.
    static func fixture(statementID: UUID, source: LeanSource, axioms: [String], messages: [LeanMessage] = []) -> Self {
        let sorries = LeanLexicon.sorries(in: source.text)
        return LeanRegionOutcome(statementID: statementID, source: source, messages: messages, sorryLocations: sorries,
                                 errorCount: messages.filter { $0.severity == "error" }.count, sorryCount: sorries.count,
                                 axiomCheck: .ran(declaration: LeanNaming.declaration(for: statementID), axioms: axioms))
    }
}
#endif
