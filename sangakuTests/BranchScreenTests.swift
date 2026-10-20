import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import sangaku

/// Plain facts for the pure tree.
private enum Facts {
    static func branch(_ name: String, _ state: BranchState = .live, at seconds: Double, main: Bool = false,
                       owner: UUID? = nil, attempt: UUID? = nil) -> BranchTree.BranchFacts {
        BranchTree.BranchFacts(id: UUID(), createdAt: Date(timeIntervalSinceReferenceDate: seconds), name: name,
                               state: state, isMain: main, isRunning: false, forkOwnerID: owner, forkAttemptID: attempt)
    }

    static func attempt(on branch: UUID, at seconds: Double, status: StatementStatus = .sketched) -> BranchTree.AttemptFacts {
        BranchTree.AttemptFacts(id: UUID(), branchID: branch, createdAt: Date(timeIntervalSinceReferenceDate: seconds),
                                author: "Model A", steps: 3, isPartial: false, status: status, verdict: nil,
                                isAdopted: false, progress: ReviewProgress([]))
    }
}

@Suite("Branches: the tree")
struct BranchTreeTests {
    @Test("Pre-order: approaches, each with its attempts, salvaged lemmas and forks; depth and links")
    func shape() {
        let main = Facts.branch("Main", at: 0, main: true)
        let attempt = Facts.attempt(on: main.id, at: 1)
        let dead = Facts.branch("Dead", .deadEnd, at: 2)
        let fork = Facts.branch("Fork", at: 3, owner: main.id, attempt: attempt.id)
        let child = Facts.branch("Child", .parked, at: 4, owner: main.id)
        let deadAttempt = Facts.attempt(on: dead.id, at: 5)
        let lemma = BranchTree.LemmaFacts(id: UUID(), createdAt: .now, label: "Lem 8", statementLaTeX: "$q > p$",
                                          status: .sketched, attemptID: deadAttempt.id)
        let tree = BranchTree.make(problemID: UUID(), title: "T", theorem: "Thm 1", theoremStatus: .sketched,
                                   branches: [fork, dead, child, main], attempts: [deadAttempt, attempt], lemmas: [lemma],
                                   showsDeadEnds: true)
        #expect(tree.nodes.map { BranchWording.title($0) }
                == ["Thm 1 · T", "Main", "Model A's attempt", "Fork", "Child", "Dead", "Model A's attempt", "Lem 8: $q > p$"])
        #expect(tree.nodes.map(\.depth) == [0, 1, 2, 3, 2, 1, 2, 3])
        #expect(tree.nodes.map(\.link) == [nil, .approach, .attempt, .fork, .fork, .approach, .attempt, .salvaged])
        #expect(tree[fork.id]?.parentID == attempt.id, "a fork from an attempt hangs under the attempt")
        #expect(tree.deadEndIDs == [dead.id] && tree.parkedIDs == [child.id])
    }

    @Test("Hiding dead ends keeps one with something live below it or a lemma salvaged from it, and counts the rest")
    func hidingDeadEnds() {
        let main = Facts.branch("Main", at: 0, main: true)
        let bare = Facts.branch("Bare", .deadEnd, at: 1)
        let withLive = Facts.branch("With a live fork", .deadEnd, at: 2)
        let live = Facts.branch("Live", at: 3, owner: withLive.id)
        let withLemma = Facts.branch("With a lemma", .deadEnd, at: 4)
        let attempt = Facts.attempt(on: withLemma.id, at: 5)
        let lemma = BranchTree.LemmaFacts(id: UUID(), createdAt: .now, label: "Lem 8", statementLaTeX: "x", status: .sketched,
                                          attemptID: attempt.id)
        let nested = Facts.branch("Nested dead", .deadEnd, at: 6, owner: bare.id)
        let tree = BranchTree.make(problemID: UUID(), title: "T", theorem: nil, theoremStatus: nil,
                                   branches: [main, bare, withLive, live, withLemma, nested], attempts: [attempt],
                                   lemmas: [lemma], showsDeadEnds: false)
        let names = tree.nodes.compactMap(\.branch?.name)
        #expect(names == ["Main", "With a live fork", "Live", "With a lemma"])
        #expect(tree.hiddenDeadEnds == 2)
    }

    @Test("The example: main with A (adopted) and B, the fork under A, and the dead ends with their messages")
    func example() throws {
        let fixture = PreviewFixtures.makeSalvaged()
        let people = fixture.state.problems.personIDs()
        let authors = AuthorDirectory(problem: fixture.problem, people: [fixture.you, fixture.mk], catalog: .standard)
        let tree = BranchTree.read(problem: fixture.problem, graph: fixture.state.graph.state(for: fixture.problem),
                                   people: people, authors: authors, running: [], live: [], showsDeadEnds: true)
        let a = try #require(tree[fixture.attemptA.stableID]?.attempt)
        #expect(a.isAdopted && a.status == .sketched, "adopted, and still only sketched: steps 3 and 5 changed since")
        #expect(tree[fixture.attemptB.stableID]?.attempt?.verdict == .gap)
        #expect(tree[fixture.fork.stableID]?.parentID == fixture.attemptA.stableID)
        #expect(tree[fixture.fork.stableID]?.branch?.inheritedMessages == 2)
        let lemma = try #require(tree.nodes.first { $0.lemma?.label == "Lem 8" })
        #expect(lemma.parentID == fixture.inductionAttempt.stableID && lemma.link == .salvaged)
        #expect(!tree.nodes.contains { $0.lemma?.label == "Lem 1" }, "the adopted proof's lemmas are the main line's")
        let dead = try #require(tree[fixture.classEquation.stableID]?.branch)
        #expect(dead.ownMessages == 2 && dead.authors == ["You", "Model A"] && dead.inContext)
        #expect(BranchWording.caption(try #require(tree[fixture.parked.stableID])) == "parked · 0 messages")
    }
}

@Suite("Branches: placement")
struct BranchTreePlacementTests {
    private func tree(depth: Int) -> BranchTree {
        var branches: [BranchTree.BranchFacts] = [Facts.branch("Root", at: 0, main: true)]
        for level in 1..<depth {
            branches.append(Facts.branch("Level \(level)", level.isMultiple(of: 3) ? .deadEnd : .live, at: Double(level),
                                         owner: branches[level - 1].id))
        }
        branches.append(Facts.branch("Sibling", .parked, at: 99, owner: branches[0].id))
        return BranchTree.make(problemID: UUID(), title: "T", theorem: nil, theoremStatus: nil, branches: branches,
                               attempts: [], lemmas: [], showsDeadEnds: true)
    }

    @Test("Nodes never overlap and stay inside the width, at the narrowest workspace and at depth 12")
    func fits() {
        for width in [WindowRoot.contentMinWidth - 2 * BranchesScreen.padding, 700] {
            let placement = BranchTreePlacement(tree: tree(depth: 12), metrics: .init(width: width))
            for slot in placement.slots {
                #expect(slot.rect.minX >= 0 && slot.rect.maxX <= width + 0.5, "\(slot.rect) in \(width)")
            }
            for (first, second) in zip(placement.slots, placement.slots.dropFirst()) {
                #expect(!first.rect.intersects(second.rect))
            }
            #expect(placement.size.height == placement.slots.last?.rect.maxY)
        }
    }

    @Test("A rail runs down the parent's left side and turns into the child; siblings never share a stretch")
    func rails() {
        let tree = tree(depth: 4)
        let placement = BranchTreePlacement(tree: tree, metrics: .init(width: 700))
        for route in placement.routes {
            let parent = placement.slot(route.parent)!.rect, child = placement.slot(route.child)!.rect
            for (from, to) in zip(route.points, route.points.dropFirst()) {
                #expect(from.x == to.x || from.y == to.y, "axis-aligned")
            }
            #expect(route.points.first!.x == parent.minX + 12 && route.points.last!.x == child.minX)
            #expect(route.points.last!.y == child.midY)
        }
        let fromRoot = placement.routes.filter { $0.parent == placement.slots[1].id }
        if fromRoot.count == 2 {
            #expect(fromRoot[1].points[0].y == placement.slot(fromRoot[0].child)!.rect.midY)
        }
        let deadEnd = tree.nodes.first { $0.branch?.state == .deadEnd }?.id
        let parked = tree.nodes.first { $0.branch?.state == .parked }?.id
        #expect(placement.routes.first { $0.child == deadEnd }?.pattern == .dashed, "a dead end's rail is dashed")
        #expect(placement.routes.first { $0.child == parked }?.pattern == .dotted, "a parked branch's is dotted")
        #expect(placement == BranchTreePlacement(tree: tree, metrics: .init(width: 700)), "the same input, the same output")
    }
}

@Suite("Branches: words, styles and choices")
struct BranchWordingTests {
    @Test("Invariant 3: nothing about a branch or the main line looks checked or verified, and glyphs are distinct")
    func styles() {
        let branchStyles = BranchState.allCases.map(StatusStyle.style(for:)) + [StatusStyle.mainLine, StatusStyle.running]
        let forbidden: Set<ColorToken> = [.verified, .verifiedFill, .modelChecked, .refuted, .refutedFill]
        for style in branchStyles {
            #expect(!forbidden.contains(style.borderToken) && !forbidden.contains(style.fill ?? .ink), "\(style.label)")
        }
        let statementGlyphs = Set(StatementStatus.allCases.map { StatusStyle.style(for: $0).glyph })
        #expect(Set(branchStyles.map(\.glyph)).count == branchStyles.count)
        #expect(Set(branchStyles.map(\.glyph)).isDisjoint(with: statementGlyphs.subtracting(["○"])),
                "only 'live' shares the open circle with 'proposed'")
        #expect(!branchStyles.map(\.glyph).contains("✓") && StatusStyle.mainLine.label == "Main line")
        #expect(StatusStyle.style(forBranch: .live, isMain: true) == .mainLine)
        #expect(StatusStyle.style(forBranch: .deadEnd, isMain: true) == StatusStyle.style(for: .deadEnd))
    }

    @Test("What a branch says: provenance, what is sent, adopting and a fork cut inside a fan-out")
    func words() {
        #expect(BranchWording.provenance(by: "You", from: "Model A's reply") == "Written by You, edited from Model A's reply.")
        #expect(BranchWording.provenance(by: nil, from: "x") == nil)
        #expect(BranchWording.sent(state: .deadEnd, inContext: true) == "Sent with every new prompt on this problem, on every branch.")
        #expect(BranchWording.sent(state: .parked, inContext: true) == "Parked branches are never sent to models.")
        #expect(BranchWording.adoptEffect(steps: 6, theorem: "Thm 1", branch: "Counting elements", alreadyMain: true)
                == "Thm 1's proof becomes these 6 steps. Counting elements stays the main line.")
        #expect(BranchWording.hiddenAttempts(1).hasPrefix("Forked inside this fan-out: 1 later attempt"))
        #expect(BranchWording.standing(.live, isMain: true, isRunning: true) == "main line, running")
        #expect(BranchWording.preview("first line\nsecond", limit: 60) == "first line")
        #expect(ReasonDraft(includeInContext: true).refusal(for: .deadEnd) == .reasonRequired)
        #expect(ReasonDraft(includeInContext: true).refusal(for: .parked) == nil)
    }

    @Test("Invariant 9: Compare offers no Adopt while blind, and names the attempts only once shown")
    func compareAdoption() {
        let fixture = PreviewFixtures.make()
        let state = ComparisonState.read(fixture.attemptA, fixture.attemptB, in: fixture.problem,
                                         people: fixture.state.problems.personIDs())
        func identity(blind: Bool) -> CompareIdentity {
            CompareIdentity.read(state, of: fixture.attemptA, fixture.attemptB, in: fixture.problem, windowBlind: blind,
                                 choice: .slot(fixture.slotC.stableID), people: [fixture.you, fixture.mk], catalog: .standard)
        }
        #expect(CompareAdoption.offer(identity: identity(blind: true), pair: state.pair, adopted: nil) == .waitingForVerdict)
        for name in ["Model", "Claude"] { #expect(!CompareAdoption.blindCaption.contains(name)) }
        guard case .choices(let choices) = CompareAdoption.offer(identity: identity(blind: false), pair: state.pair,
                                                                 adopted: fixture.attemptA.stableID) else {
            Issue.record("choices once shown")
            return
        }
        #expect(choices.map(\.attemptID) == [state.pair.first, state.pair.second])
        #expect(choices.allSatisfy { $0.title.hasPrefix("Adopt Attempt \($0.side) · Model ") && $0.title.hasSuffix(" as Main Line…") })
        #expect(choices.first { $0.attemptID == fixture.attemptA.stableID }?.isAdopted == true)
    }

    @Test("Every action the menus offer is one the manager allows, on every branch of the example, running or not")
    func offers() throws {
        // Held, so the store outlives the count.
        let probe = PreviewFixtures.make()
        let count = probe.problem.sortedBranches.count
        for index in 0..<count {
            for action in BranchOffers.Action.allCases {
                for isRunning in [false, true] {
                    let fixture = PreviewFixtures.make()
                    let branch = fixture.problem.sortedBranches[index]
                    let activity = TestActivity()
                    if isRunning {
                        // A running request is writing the branch's latest message.
                        activity.streamingBranchIDs = [branch.stableID]
                        activity.liveMessageIDs = Set(branch.visibleHistory.all.suffix(1).map(\.stableID))
                    }
                    let offers = fixture.offers(for: branch, activity: activity)
                    guard offers.applies(action) else { continue }
                    let manager = fixture.branchManager(activity: activity)
                    let done = switch action {
                    case .markDeadEnd: (try? manager.markDeadEnd(branch, ReasonDraft(reason: "x"))) != nil
                    case .park: (try? manager.park(branch, ReasonDraft())) != nil
                    case .reopen: (try? manager.reopen(branch)) != nil
                    case .editReasons: (try? manager.editReasons(of: branch, ReasonDraft(reason: "x"))) != nil
                    case .cherryPick: (try? manager.cherryPickTarget(of: branch)) != nil
                    case .newBranch:
                        branch.visibleHistory.all.last.flatMap { try? manager.fork(from: $0.stableID, named: "Probe") } != nil
                    }
                    #expect(offers.allows(action) == done, "\(branch.name), \(action), running: \(isRunning)")
                    if !offers.allows(action) { #expect(!offers.refusals.isEmpty, "a refusal is said in words") }
                }
            }
        }
    }

    @Test("Invariant 9: while blind mode hides the authors, no sheet that names them opens, from any screen")
    func blind() throws {
        let fixture = PreviewFixtures.make()
        let activity = TestActivity()
        let hidden = fixture.offers(for: fixture.fork, activity: activity, hidesAuthors: true)
        for action in hidden.actions {
            #expect(hidden.refusal(action) == (action.waitsWhileBlind ? .blind : nil), "\(action)")
        }
        #expect(hidden.refusals.contains(BranchError.blind.message))
        for name in ["Model", "Claude", "Anthropic"] { #expect(!BranchError.blind.message.contains(name)) }
        let tree = BranchTree.read(problem: fixture.problem, graph: fixture.state.graph.state(for: fixture.problem),
                                   people: fixture.state.problems.personIDs(), authors: AuthorDirectory(
                                       problem: fixture.problem, people: [fixture.you, fixture.mk], catalog: .standard),
                                   running: [], live: [], showsDeadEnds: true, hidesAuthors: true)
        #expect(tree.nodes.compactMap(\.branch?.offers).allSatisfy { $0.hidesAuthors })

        let window = WindowState()
        window.select(problem: fixture.problem)
        window.blindMode = true
        window.activeView = .compare
        let manager = fixture.branchManager(activity: activity)
        for intent in [BranchIntent.fork(messageID: fixture.reply.stableID), .newBranch(branchID: fixture.fork.stableID),
                       .markDeadEnd(branchID: fixture.fork.stableID), .park(branchID: fixture.fork.stableID),
                       .editReasons(branchID: fixture.parked.stableID), .cherryPick(branchID: fixture.induction.stableID)] {
            BranchIntentHandler.perform(intent, window: window, branches: manager)
            #expect(window.branchSheet == nil, "\(intent)")
        }
        // A sheet asked for before blind mode came on is not shown while it holds, and returns once it is off.
        window.blindMode = false
        BranchIntentHandler.perform(.markDeadEnd(branchID: fixture.fork.stableID), window: window, branches: manager)
        window.blindMode = true
        #expect(window.branchSheet != nil && BranchSheetHost.presented(in: window) == nil)
        window.activeView = .branches
        #expect(BranchSheetHost.presented(in: window) == window.branchSheet)
        // Adopt names nothing new: Compare offers it only once the attempts are shown (`CompareAdoption`).
        window.activeView = .compare
        BranchIntentHandler.perform(.adopt(attemptID: fixture.attemptB.stableID), window: window, branches: manager)
        #expect(BranchSheetHost.presented(in: window) == .adopt(attemptID: fixture.attemptB.stableID))
    }

    @Test("Invariant 3: a node's words never claim more than its frame: A's verdict is out of date, B's has a gap")
    func captions() throws {
        let fixture = PreviewFixtures.make()
        fixture.messageA.interrupted = true
        let tree = BranchTree.read(problem: fixture.problem, graph: fixture.state.graph.state(for: fixture.problem),
                                   people: fixture.state.problems.personIDs(), authors: AuthorDirectory(
                                       problem: fixture.problem, people: [fixture.you, fixture.mk], catalog: .standard),
                                   running: [], live: [], showsDeadEnds: true)
        let a = try #require(tree[fixture.attemptA.stableID])
        let b = try #require(tree[fixture.attemptB.stableID])
        #expect(BranchWording.caption(a).contains("referee: complete, but steps 3 and 5 changed since"))
        #expect(a.attempt?.status != .modelChecked, "a verdict on earlier text vouches for nothing")
        #expect(BranchWording.caption(b).contains("referee: gap at step 5"))
        for node in tree.nodes {
            guard let attempt = node.attempt else { continue }
            if BranchWording.referee(attempt) == "referee: complete" {
                #expect(attempt.warnings.isEmpty || attempt.warnings == [.partial], "\(BranchWording.caption(node))")
            }
        }
        let problem = try #require(tree.nodes.first)
        #expect(BranchWording.caption(problem).contains("its adopted proof is partial"))
        #expect(BranchWording.sentence(problem, spokenTitle: "Theorem 1").hasPrefix(BranchWording.style(problem).label + ": Theorem 1. "))
    }

    @Test("The Branches menu's handle is compared by what its command reads, never by its closure")
    func control() {
        let presenter = UUID(), nodes = [UUID(), UUID()]
        let offers = BranchOffers(state: .live, isMain: false, isRunning: false, hasMessages: true, hasAttempts: true)
        let one = BranchesControl(presenter: presenter, nodes: nodes, current: nodes[0], branchID: nodes[0], offers: offers) { _ in }
        let same = BranchesControl(presenter: presenter, nodes: nodes, current: nodes[0], branchID: nodes[0], offers: offers) { _ in }
        #expect(one == same)
        var running = offers
        running.isRunning = true
        #expect(one != BranchesControl(presenter: presenter, nodes: nodes, current: nodes[0], branchID: nodes[0],
                                       offers: running) { _ in })
        #expect(one != BranchesControl(presenter: presenter, nodes: nodes, current: nodes[1], branchID: nodes[0],
                                       offers: offers) { _ in })
        #expect(one.allows(.park) && !one.allows(.reopen))
    }

    @Test("Edges: the selection's last, a point wider and darker; a refuted dependency dashed in its colour")
    func strokes() {
        let (x, y, z) = (UUID(), UUID(), UUID())
        let line = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 10)]
        let routes = [GraphPlacement.Route(dependency: x, user: y, points: line),
                      GraphPlacement.Route(dependency: z, user: x, points: line),
                      GraphPlacement.Route(dependency: y, user: z, points: line)]
        let graph = StatementGraphView.strokes(routes, selectedID: y, refuted: [z], width: 1)
        #expect(graph.map(\.ink) == [.colour(.refuted), .emphasised, .emphasised])
        #expect(graph.map(\.width) == [1, 2, 2] && graph.map(\.dash) == [[4, 3], [], []])
        #expect(graph.allSatisfy { $0.arrowhead })
        #expect(StatementGraphView.strokes(routes, selectedID: nil, refuted: [], width: 1.5).map(\.width) == [1.5, 1.5, 1.5])

        let rails = [BranchTreePlacement.Route(parent: x, child: y, points: line, pattern: .dashed),
                     BranchTreePlacement.Route(parent: y, child: z, points: line, pattern: .dotted)]
        let drawn = BranchTreePlacement.strokes(rails, selectedID: z, width: 1)
        #expect(drawn.map(\.ink) == [.plain, .emphasised] && drawn.map(\.dash) == [[5, 3], [1.5, 3]])
        #expect(drawn.map(\.width) == [1, 2] && !drawn.contains { $0.arrowhead })
        #expect(EdgeStroke.baseWidth(increasedContrast: true) > EdgeStroke.baseWidth(increasedContrast: false))
    }

    @Test("A fork made at a fan-out's prompt shows none of its attempts and says where they are")
    func fanOutAtThePrompt() {
        let header = FanOutHeader(visibility: .independent, attempts: [], refereeLetter: "C", referee: .waiting)
        #expect(header.title == "No attempts on this branch")
        #expect(header.visibilityLine == "Independent attempts, on the parent branch")
        #expect(!header.title.contains("0"))
    }

    @Test("Review Steps in the inspector shows the branch a lemma's steps were written on, unless it is shown already")
    func reviewSwitchesBranch() throws {
        let fixture = PreviewFixtures.makeSalvaged()
        let graph = fixture.state.graph.state(for: fixture.problem)
        let salvaged = try #require(graph.nodes.first { $0.label == "Lem 8" })
        let window = WindowState()
        window.select(problem: fixture.problem)
        window.openReview(statement: salvaged, in: fixture.problem)
        #expect(window.selectedBranchID == fixture.induction.stableID)
        #expect(window.review.candidateAttemptIDs == [fixture.inductionAttempt.stableID] && window.activeView == .review)
        // Lemma 3 rests on A's steps, which the fork shows by inheritance: the window stays on the fork.
        window.switchBranch(to: fixture.fork.stableID)
        window.openReview(statement: try #require(graph[fixture.lemmas[2].stableID]), in: fixture.problem)
        #expect(window.selectedBranchID == fixture.fork.stableID)
        #expect(window.review.candidateAttemptIDs == [fixture.attemptA.stableID])
    }

    @Test("Switching branch: Thread, Review and Compare follow; the Branches selection and the problem do not move")
    func window() {
        let window = WindowState()
        let problem = UUID(), branch = UUID(), node = UUID()
        window.selectedProblemID = problem
        window.branchesSelection = node
        window.review.attemptID = UUID()
        window.compare.picked = [UUID(), UUID()]
        window.switchBranch(to: branch)
        #expect(window.selectedBranchID == branch && window.selectedProblemID == problem && window.branchesSelection == node)
        #expect(window.review == ReviewSelection() && window.compare == CompareSelection())
        window.openMessages(of: UUID())
        #expect(window.activeView == .thread)
        window.showInBranches(node)
        #expect(window.activeView == .branches && window.branchesSelection == node)
        window.select(problem: nil)
        #expect(window.branchesSelection == nil && window.branchSheet == nil)
    }
}

@Suite("Branches: layout and renders", .serialized)
struct BranchLayoutTests {
    private let fixture = PreviewFixtures.makeSalvaged()

    private func environment<V: View>(_ view: V) -> some View {
        view.appEnvironment(fixture.state)
            .environment(\.mathContext, fixture.mathContext)
            .modelContainer(fixture.state.container)
    }

    private var tree: BranchTree {
        BranchTree.read(problem: fixture.problem, graph: fixture.state.graph.state(for: fixture.problem),
                        people: fixture.state.problems.personIDs(), authors: authors, running: [], live: [],
                        showsDeadEnds: true)
    }

    private var authors: AuthorDirectory {
        AuthorDirectory(problem: fixture.problem, people: [fixture.you, fixture.mk], catalog: .standard)
    }

    private var carries: PromptCarries {
        PromptCarries(ProblemSnapshot.stable(problem: fixture.problem,
                                             notation: fixture.state.problems.notation(for: fixture.problem),
                                             people: [fixture.you, fixture.mk]))
    }

    private func panel(_ id: UUID) -> some View {
        BranchPanel(problem: fixture.problem, node: tree[id]!, tree: tree, window: WindowState(), authors: authors,
                    offers: tree[id]?.branch?.offers)
    }

    @Test("The tree, the panel and the summary fit the narrowest workspace; the screen fits a window of the minimum size")
    func fits() {
        let narrow = WindowRoot.contentMinWidth - 2 * BranchesScreen.padding
        func width(_ view: some View) -> CGFloat {
            NSHostingController(rootView: environment(view)).sizeThatFits(in: CGSize(width: narrow, height: .greatestFiniteMagnitude)).width
        }
        let placement = BranchTreePlacement(tree: tree, metrics: .init(width: narrow))
        #expect(width(BranchTreeView(tree: tree, placement: placement, selectedID: nil, shownBranchID: nil, onSelect: { _ in })) <= narrow)
        #expect(width(panel(fixture.classEquation.stableID)) <= narrow)
        #expect(width(PromptCarriesCard(carries: carries)) <= narrow)
        let window = WindowState()
        window.select(problem: fixture.problem)
        let size = NSHostingController(rootView: environment(BranchesView(problem: fixture.problem, window: window)))
            .sizeThatFits(in: .zero)
        #expect(size.width <= WindowRoot.contentMinWidth)
        #expect(size.height <= WindowRoot.minimumHeight - 52)
        // Laid out wide, both ways, the content still asks for no width of its own: AppKit sizes the window's
        // column from the content's minimum, and a content that held its width would hold the column at it.
        for (width, mode) in [(1_200.0, BranchesLayoutMode.sideBySide), (600, .stacked)] {
            @FocusState var focused: Bool
            let content = BranchesContent(problem: fixture.problem, window: window, tree: tree, selected: nil,
                                          shown: fixture.mainBranch.stableID, offers: nil, carries: carries,
                                          authors: authors, mode: mode, width: width, display: .constant(.tree),
                                          listFocused: $focused)
            #expect(NSHostingController(rootView: environment(content)).sizeThatFits(in: .zero).width
                    <= WindowRoot.contentMinWidth, "\(mode)")
        }
    }

    /// With `SANGAKU_PREVIEW_DIR` set, writes PNGs for a visual check (pass `TEST_RUNNER_SANGAKU_PREVIEW_DIR`).
    private func render(_ name: String, width: CGFloat, dark: Bool = false, @ViewBuilder _ view: () -> some View) throws {
        let content = environment(view())
            .frame(width: width)
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try #require(renderer.cgImage, "\(name) did not render")
        if let folder = ProcessInfo.processInfo.environment["SANGAKU_PREVIEW_DIR"] {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appending(path: "\(name).png"))
        }
    }

    @Test("Smoke renders: the tree and outline, the panels, the summary, the sheets and the thread's fork header")
    func renders() throws {
        let tree = tree
        try render("branches-tree", width: 640) {
            BranchTreeView(tree: tree, placement: BranchTreePlacement(tree: tree, metrics: .init(width: 640)),
                           selectedID: fixture.classEquation.stableID, shownBranchID: fixture.mainBranch.stableID,
                           onSelect: { _ in })
        }
        try render("branches-tree-dark", width: 640, dark: true) {
            BranchTreeView(tree: tree, placement: BranchTreePlacement(tree: tree, metrics: .init(width: 640)),
                           selectedID: nil, shownBranchID: nil, onSelect: { _ in })
        }
        try render("branches-outline", width: 360) {
            BranchOutlineView(tree: tree, selectedID: fixture.fork.stableID, shownBranchID: nil, onSelect: { _ in })
        }
        try render("branches-panel-dead-end", width: 340) { panel(fixture.classEquation.stableID) }
        try render("branches-panel-main", width: 340) { panel(fixture.mainBranch.stableID) }
        try render("branches-panel-attempt", width: 340) { panel(fixture.attemptB.stableID) }
        try render("branches-carries", width: 340) { PromptCarriesCard(carries: carries) }
        try render("branches-reason-sheet", width: 560) {
            ReasonSheet(problem: fixture.problem, branchID: fixture.classEquation.stableID, mode: .edit)
        }
        try render("branches-adopt-sheet", width: 520) {
            AdoptSheet(problem: fixture.problem, attemptID: fixture.attemptB.stableID)
        }
        try render("branches-new-sheet", width: 480) {
            NewBranchSheet(problem: fixture.problem, messageID: fixture.messageA.stableID) { _ in }
        }
        try render("branches-thread-header", width: 700) {
            BranchHeader(problem: fixture.problem, branch: fixture.fork, history: fixture.fork.visibleHistory,
                         authors: authors)
        }
    }
}
