# Decisions

Settled decisions, newest first. Each records what was decided, when, and why. Open questions stay in the spec's
*Open decisions* list until they move here.

## 2026-10-19: Milestone 7 architecture and choices

- **Architecture.** The "clean" blueprint, chosen at the milestone's architecture step, with the trust guards of the
  "pragmatic" one.
  - A pure core (`Model/Values/Branches`): the history rule, the reasons rule, the adoption assessment, what can be done
    to a branch (`BranchOffers`) and the tree.
  - `BranchManager` is the only writer of a branch's state and texts, of the main-line pointer once a problem exists,
    and of the adoption record. Every write is a person's, in the name of the person using the app.
  - The theorem's proof is set only through `StatementGraph.adoptProof`, so statements keep one writer.
    `ThreadManager` stays the only owner of requests; `BranchManager` reads what is running and cancels nothing.
- **Schema** (V1 edited in place, additive):
  - On `Branch`: who changed its state, and who wrote each reason, when and from which message.
  - On `Problem`: the adopted attempt, who adopted it and when.
  - `BranchState` keeps live, dead end and parked. The main line is `mainBranchID` alone and "running" is derived
    from the requests in flight; stored "adopted" or "running" values read as live.
  - A copy of the existing store opened with the new schema, without a reset.
- **A fork carries its history.** Chosen in the milestone's questions.
  - A branch forked from a message reads its parent's history up to and including that message, cut by position and
    recursively, then its own messages. Nothing is copied, so IDs, `derivedFromIDs` and fan-out grouping stay
    intact (invariant 4).
  - One function decides it. What models are sent (`ProblemSnapshot.make`), the thread, Review and Compare all take
    `Branch.visibleHistory`, and only that function makes one, so the screen never shows something other than what
    the model is sent.
  - A missing fork point or a cycle fails closed: the branch's own messages, a stated fault, and nothing sent.
  - Inherited messages are the oldest, so a short window leaves them out first; each is listed as "before the
    fork" (invariant 5).
  - A fork made inside a fan-out shows only the attempts before the fork point. A referee there is refused, as it
    would judge only some of them.
  - A fork's new messages are stamped after everything it shows. A person's revision is stamped after every message
    in the problem, so a referee running on a fork never seems to have seen it (rule 4).
- **Forking** works from any message's menu or VoiceOver action, and from New Branch on the Branches screen (the
  shown branch's latest message). It is refused while the message, or one before it, is still being written. Names
  are one line and unique in the problem.
- **Closed branches send nothing.** Every request that writes on a branch passes through `ContextBuilder`, which
  refuses a dead end or parked branch ("Reopen it to continue"). An alignment, which writes nothing on the branch,
  may still compare attempts on one. The composer shows the reason with a one-click Reopen and keeps the draft.
- **Dead ends and reasons.** Chosen in the milestone's questions.
  - Marking a dead end turns In Context on by default. With it on, a reason is required, since models would
    otherwise be told "(no reason recorded)".
  - Parked branches are never sent.
  - Reopening keeps the reasons as history. The main line, and a branch with a request running, cannot be retired.
  - Both texts are written by people. Each can start from a message the branch shows, which is recorded ("Written by
    You, edited from Model A's reply"). No model writes or drafts a reason.
- **Adopt = proof + main line.** Chosen in the milestone's questions.
  - Adopting an attempt sets the theorem's source steps to its steps, records who adopted which attempt and when, and
    makes the branch the attempt was written on the main line. Chosen in the architecture step; adopting from a fork
    names that branch.
  - The theorem's status then derives from the steps as for any statement, so adopting checks nothing (invariants 1
    and 13).
  - A gap, an unrefereed or revised attempt, or a partial one can be adopted once its warnings are acknowledged. If
    what is known changes before confirming, the adoption is refused and the warnings are shown again.
  - An attempt on a closed branch is refused ("Reopen it first"). A referee's "complete" adopts nothing.
  - In Compare, Adopt waits while blind mode hides the authors, and names attempts only through `CompareIdentity`
    (invariant 9). Adopting records no blind verdict.
- **The main line's mark is ◆, not ✓.** Chosen in the architecture step. ✓ is "checked by a person", and the main line
  is a person's choice, not a check. Its frame is a light neutral fill in ink, so an adopted proof nobody checked
  never looks checked (invariant 3). "Running" is ● in ink, since blue means checked by a model.
- **Cherry-pick = salvage as a lemma.** Chosen in the milestone's questions. "Cherry-pick a step" opens Promote on the
  branch's own attempts. The lemma refers to the original steps, so their reviews, verdict and authors count as they
  are, and the tree shows it under the attempt it came from.
- **No deletion** of branches or messages. Chosen in the milestone's questions. A branch is retired by marking it a
  dead end or parked, and reopened. A test pins that every deletion in the app is of a problem, a notation entry, a
  review or a statement. This closes the Milestone 4 risk to lemmas' source steps.
- **Switching branch.** Chosen in the milestone's questions.
  - Clicking a branch in the sidebar shows it in Thread, Review and Compare. Open Messages does the same and goes to
    the thread, which says which branch it is on and where a fork came from.
  - Sidebar branch rows are buttons, never tagged into the list's problem selection.
  - Selecting a node on the Branches screen fills its panel only.
- **The Branches screen.**
  - The tree is drawn on its side, one row per node in reading order and indented under its parent, so it wraps to
    any width and reads in the same order as the outline and VoiceOver. Rails run down the parent's side, dashed to
    a dead end and dotted to a parked branch. An outline display drops the frames.
  - Each attempt is framed by the status a statement resting on its steps would earn, never more.
  - The panel shows what the branch is and where it came from, why it died with its provenance, and the exact line
    models are sent with the In Context toggle. Its actions are disabled with the reason in words.
  - "What every new prompt carries" uses the same snapshot and line functions as `ContextBuilder` (`PromptCarries`).
  - J and K, the Branches menu and rotors move through it.
  - The inspector's placed layout and edge drawing were made shared components.
  - **Layout rule:** content laid out at a measured width must not ask for that width. AppKit sizes the window's
    column from the content's minimum, and an early tree that held its width put the window into a constraint loop
    that aborted it.
- **After the review.**
  - Blind mode gates every branch sheet that names who wrote what (New Branch, the reasons sheet, Cherry-pick), not
    only Compare's Adopt. The handler refuses it while blind mode hides the authors, whichever screen asked, and the
    sheet host does not show one asked for earlier until blind mode is off or Compare is left (invariant 9). Reopen
    names nobody, and Compare offers Adopt only once the attempts are shown, so neither waits.
  - One source of branch actions. The sidebar's menu, the tree's node menu, the Branches panel and the Branches menu
    all draw the items `BranchOffers` gives, with its refusals in words. A test runs every action on every branch of
    the example, running or not, against the manager.
  - New Branch from a branch's latest message is refused while a request runs on the branch: that message is still
    being written.
  - Running is drawn as ● in ink on the tree's node, the thread's branch header and the panel.
  - A node's caption never says more than its frame. A "complete" verdict given before a step changed reads
    "complete, but steps 3 and 5 changed since".
  - Review Steps in the inspector shows the branch a statement's steps were written on when the window's branch does
    not show them.
  - Branch intents carry stable IDs and are resolved through the manager when handled, so a handler kept across a
    problem switch acts on the right branch.
  - Branch names are drawn with `MathText` and spoken as it speaks them, never as LaTeX source.

## 2026-10-19: Milestone 6 architecture and choices

- **Architecture.** The "clean" blueprint, chosen at the milestone's architecture step, with the blind-mode safeguards
  of the "pragmatic" one.
  - A pure core (`Model/Values/Compare`): `ComparisonState` derives the table on every read from three layers, a
    person's corrections over the model's rows over the pairing by label. Every step of both attempts is in exactly
    one row whatever the stored layers say (a property test over 200 random cases).
  - `AlignmentService` is the only writer of a person's corrections and blind verdict. `ThreadManager` stays the only
    owner of request tasks and of what requests write, so it stores a model's alignment rows when the request ends.
  - Nothing reads a comparison to decide a status or a review: a comparison is a reading, never a check (invariant 1).
- **Schema** (V1 edited in place, additive): on `Alignment`, `correctionsJSON`, `modelRunID`, `alignerSlotID`,
  `modelSummary`, the blind verdict (`holdsRaw`, `holdsByID`, `holdsAt`) and `requests`; `RequestRecord.alignment`;
  optional fields on `AlignmentRow` (note, key phrases, the revisions the model was shown); the message kind
  `refereeReply`. A copy of the existing store opened with the new schema, without a reset.
- **Rows: labels first, the model on request.** With nothing stored, steps pair by what they establish (normalised
  labels, the k-th with the k-th) and the rows say "not compared": a label never makes a row equivalent. "Align…" asks
  a model to pair and judge, with the estimate shown first. Chosen in the milestone's questions.
- **A person's corrections survive a new alignment.** They are an append-only log (pair, separate, judge, clear),
  replayed over whatever the model said. A separated pair never comes back by label. A judgement is given on the
  revisions read; a step revised since makes the row out of date, and a step with no recorded revision cannot be
  judged.
- **Separating withdraws a judgement.** Separating two steps, or pairing either with another step, withdraws the
  person's judgement of them: paired again, they start unjudged. Chosen at the milestone's review.
- **Out of date.** A row judged on a revision a step no longer has is "out of date": never counted as equivalent, never
  collapsed in the thread. The model's note and key phrases are shown only while its reading covers both steps' text,
  even on a row a person has since judged. A model's "no counterpart" goes out of date when its step is revised; a
  person's separation does not. An unrecorded revision counts as out of date.
- **The aligner is the fan-out's referee** when both attempts belong to one, else the only referee-role slot, else the
  person chooses; a slot that wrote either attempt never aligns it. Chosen in the milestone's questions.
  `ThreadManager.align` enforces this itself, refuses one attempt given twice, and orients the pair as Compare shows
  it whatever order it is passed in.
- **What the aligner is shown.** The two attempts, named only "Attempt 1" and "Attempt 2", with their current text, and
  the problem's stable sections; nothing else of the thread, since the prompt names the slots. It has its own prompt
  (`aligner@1`). Its answer is read whole or not at all; a stopped or failed alignment stores nothing and the earlier
  rows stay.
- **The alignment request belongs to the comparison**, not to a message: its record hangs off the `Alignment`, so it
  never enters the thread or a later context. Stop, quit, deleting the problem and orphan recovery handle it like any
  request. A hidden message on the branch was considered and rejected: every reader of messages would have had to
  filter it.
- **Side order.** Which attempt is "Attempt 1" is fixed per pair from the two attempts' IDs (a hash), never from slot
  letters or the order they were picked in. The columns never swap, blind or not.
- **Blind mode** (invariant 9): the authors of a comparison stay hidden while blind mode is on and the person has not
  recorded which attempt holds (1, 2, both or neither). Recording reveals that comparison only, and changes no check
  or status. Chosen in the milestone's questions. While blind:
  - Identity reaches Compare's views only through `CompareIdentity`, built once per render. While hidden it holds no
    author, letter, colour or directory to look one up in; the aligners are "the referee" or "Referee 2". The
    attempt pickers are replaced by "Comparing Attempt 1 and Attempt 2".
  - Text a model or provider wrote is withheld when it names a model, a slot letter in an identifying form, or a
    provider (`BlindShield`): a row's note and label, the summary, the error of a failed alignment, and what was
    left out of the aligner's context. A withheld label gives way to what a step of the row establishes. Why
    aligning cannot be sent is worded without the aligner's letter or provider.
  - The toolbar's model chips and the proof-structure inspector are hidden in Compare, failing closed until blind
    mode is turned off.
  - Aligning stays available; its estimate names "the referee". Repair and row-to-referee requests wait for the
    verdict, since their thread messages name the models.
  - A stored verdict this version cannot read counts as recorded (the authors are shown) and is never written over,
    as unreadable corrections are not. Chosen at the milestone's review.
- **Re-pairing** by drag and drop (a step onto a row of the other attempt) and, equally, by each row's menu and
  context menu: pair with, separate, mark equivalent or diverging, clear one's judgement. VoiceOver has the last four
  as actions on the row and reaches "pair with" through the row's menu. A dragged step travels as its own content
  type (`local.sangaku.step`, declared in `Config/sangaku-Info.plist`), so no text field accepts it.
- **Key phrases** are kept only where they leave every formula of the step whole (invariant 16), checked when the
  answer is stored and again when it is drawn. They are marked, and spelled out under the step ("Where they part:
  …") in case the mark cannot be drawn.
- **Keyboard.** J and K move between rows while the row list has the keyboard; the Compare menu has Next Row,
  Previous Row, Differences Only and Align…, with no key equivalents, as in Review. The filter is a window setting
  kept across comparisons.
- **Questions about a row.** "Ask … to repair step N" goes to the author of that side; "Send this row to …" goes to the
  referee, which answers in prose with its own prompt (`referee-reply@1`) and never gives a verdict. Both are ordinary
  thread messages, shown and editable before they are sent, at the think-time chosen in the branch's composer. They
  are linked to both attempts (`derivedFromIDs`), so wherever the attempts are withheld from a model (invariant 4),
  so are they. A later fan-out sees them as it sees the attempts themselves. Nothing changes a step until a person
  revises it.
- **The thread** reads the stored comparison of a fan-out's first two attempts: the later attempt's runs of steps
  judged equivalent on the current text collapse to "Steps 1–4 match A's", and a banner names the row where they part.
  A step that asks for attention never collapses: one the referee listed as a gap, a delicate step or a guess, or one
  with an open objection or a re-check flag. The referee message has "Compare Attempts".
- **What the aligner's context leaves out** to fit its window is listed in the Align sheet before sending
  (invariant 5), as the composer does.
- **Layout.** Four columns from 680 points of content, one card per row below.
- **Adopt** (Milestone 7) and the **counterexample search** (Milestone 8) are shown disabled with a caption.

## 2026-10-18: Milestone 5 architecture and choices

- **Architecture.** The "clean" blueprint, chosen at the milestone's architecture step, with two adjustments: the
  keyboard design (one focusable step list) and the context wording below.
  - One per-step rule, `StepStandings.derive`, reads a step's reviews and the referee's verdict. Statement status
    (rules 3 and 4), the Review chips, the progress line and the rotors all read it, so they cannot disagree. A
    property test compares it with the spec's rule, written out naively, on 200 random attempts.
  - `ReviewManager` is the only writer of reviews, dismissals, withdrawals, comments and person revisions. Every
    write is in the name of the person using the app (`problems.me()`); no parameter names a reviewer, and nothing a
    model sends reaches the manager (invariant 1).
  - Standings are derived on every read, never stored.
- **Schema** (V1 edited in place while the store is scratch): a `StepComment` entity (deleted with its step, author
  in two columns, the revision it was written on), `Step.comments`, `Review.withdrawnAt` and
  `RefereeVerdict.requestedAt`; the unused `Review.isDismissed` was removed. The existing store opened without a
  reset: a copy was opened with the new schema first, and SwiftData migrated the additive changes on its own.
- **Rule 4 is tightened; this reverses part of the Milestone 3 "Rule 4" entry.** That entry declined "a verdict must
  postdate the step's revisions". Now a verdict covers a step only if the step's current revision is no later than
  the referee's request (`requestedAt`, the referee message's creation time): what the referee saw, not when its
  verdict was stored. A verdict with no request time covers no step, so verdicts stored before Milestone 5 no longer
  count and their statements show sketched until the attempt is refereed again. Tied verdicts cover only what the
  earliest request saw. Chosen in the milestone's questions. In the example, steps 3 and 5 were revised after the
  referee's pass, so Thm 1 and Lem 3 are sketched and Lem 5 is capped by Lem 3.
- **Review shows one attempt**, chosen with a picker. Without a choice: the attempts of the referee message Review
  was opened from (the first the referee found complete), else the theorem's source attempt, else the newest
  refereed attempt, else the newest. Attempts still streaming or declined are not offered; partial ones are, marked.
  Chosen in the milestone's questions.
- **Entry points.** The referee's "Review Step by Step", a step's "Review This Step", and the inspector's "Review
  Steps", which replaces "Mark Checked": no button sets a status; checking happens on the steps.
- **Objections.** A ✗ or ? closes by a new revision, by a person's dismissal with a reason (any person, not only the
  one who raised it), or by its raiser's withdrawal (see Withdrawal). A later ✓ never closes it. The dismissal sheet offers "Also mark this version ✓", off by
  default, so closing an objection is never a check by itself. One "Dismiss…" button replaces the blueprint's
  separate Dismiss and Resolve, which did the same with the option off.
- **Withdrawal.** A person can withdraw their own marks; they stay in the history, marked withdrawn. A ✓ stops
  counting; withdrawing takes back every ✓ they gave on that version (a re-checked step can hold two). A ✗ or ? closes,
  with no reason asked, since the person who raised it is taking it back; anyone else closes it by dismissal with a
  reason. A withdrawal counts only from a person, so one that cannot be traced to a person leaves the objection open.
  Chosen after the milestone, when an accidental key press turned out to be hard to take back. This relaxes the
  spec's rule that an objection closes only by a revision or a dismissal with a reason.
- **Undo.** A mark made since sangaku opened can be taken back outright, as if never given, while nothing has been
  recorded on its step after it: with the Undo button beside the confirmation, or Edit > Undo (⌘Z), with Redo. Older
  marks, and marks something was recorded after, are withdrawn or dismissed instead and stay in the history. Undo
  uses the window's undo manager, so text typed in a comment field shares the stack; the confirmation goes away when
  a text field takes the keyboard, so its Undo button never takes back typing. Chosen with withdrawal.
- **Repeats.** Marking ✓ again records nothing while that ✓ stands on the current version and no earlier step has
  changed what it establishes since. Otherwise a fresh ✓ is recorded, which clears a re-check flag; this holds beside
  an open objection too, so the ✓ is fresh once the objection closes. A ✗ beside one's own open ? is a second
  objection, each closed on its own. Holding a key repeats J and K only.
- **Re-check flags** are shown and counted in the progress notes; a flagged step still counts as checked. The flag is
  ⚑, not ↻, which already marks a cycle.
- **Comments** are written on one revision and carry no verdict. They are not sent to models, so a comment schedules
  a save but does not rebuild the composer's estimate. An unsent comment is kept per step while the app runs, like
  the thread's drafts, and a step with one says so.
- **People edit steps** with Revise…: a new revision in their name, the earlier versions kept. Reviews of the old
  text stop counting (invariant 2). Chosen in the milestone's questions.
- **Times only move forward.** Each write is timed after everything already recorded on the attempt (revisions,
  reviews, dismissals, withdrawals, comments, the referee's request and verdict times) and after every message on its
  branch, so a referee request still running counts too. A clock running behind can then never make a person's
  revision look seen by the referee, or a ✓ look older than the change it answers.
- **What models are told.** A step a person revised carries "; revised by the researcher" (the person using the app,
  since "you" is the model in a prompt) or the collaborator's name. The prompt files are unchanged.
- **Keyboard.** The step list is one focusable view; J, K, 1, 2, 3 and C act only while it has the keyboard. Three
  checks keep them from acting while someone types: the text fields are where the list's focus is not, Review's own
  focus state, and whether a text view is first responder. Any modifier passes the key on, so ⌘-shortcuts work.
  Marking does not move on to the next step. The current step's ring is solid while the list has the keyboard and
  faint otherwise; with no current step, the list itself is ringed. The Review menu repeats the commands with no key
  equivalents, since a plain-letter shortcut would act while typing. VoiceOver rotors: "Unchecked steps" (objected
  ones included) and "Delicate steps"; every row has a "Make Current" action, and a ✓ beside an open objection is
  announced as blocked, never as counting.
- **Look.** The margin bar has a segment per author in version order, with their letters or initials beside the step
  number. Chips always show a glyph and words: ○ not checked by a person; ✓ initials and time; ✗ or ? "open" with who
  raised it; ◐ "Checked by C only" or "Also checked by C"; △ a gap found here; – "C's check covered an earlier
  version"; ⚑ re-check. An open ✗ is not drawn as a refuted statement (invariant 1). Unchecked text is drawn in the
  secondary ink; a row a person's ✓ counts for has an ink border, as the token table says.
- **People in Review.** A person whose record is gone is "Someone no longer listed" everywhere. If two records are
  marked as the person using the app, the earliest counts, in every reader. Letter and initials badges take the
  background colour for their text, so they read in dark mode too.
- **The step list is not lazy**: attempts have few steps, and scrolling to a step and the rotors need every row.
- **The side panel** (Lean, citations, evidence, export) stays with Milestone 8.

## 2026-10-17: Milestone 4 architecture and choices

- **Architecture.** The "clean" blueprint, chosen at the milestone's architecture step:
  - A pure core in `Model/Values`: `StatusDerivation` (the cap), `UsesGraph` (the cycle check),
    `StatementLabels`, `StatementGraphState` (a problem's statements as values, with displayed status and why)
    and `PromotionDraft`; `GraphPlacement` (layers, rows, edge routes) in `Views/Inspector`.
  - `StatementGraph` is the only writer of promoted statements and `uses` edges. `ProblemManager` creates each
    problem's theorem and keeps its text equal to the problem statement, since its row in the spec owns the pinned
    statement.
  - Status is read from the store on every render and never cached. A test confirms that a verdict or review
    linked from its own side still tells the views to read again, so no extra watcher was added.
  - Reason: the cap and the cycle check are invariant 13. As pure functions over values they are tested
    exhaustively, including 200 random graphs against a reference.
- **The cap.** A statement displays the lowest of its own status and the displayed status of what it uses. A
  refuted dependency lets only `sketched` through, and "depends on a refuted claim" is shown through any number of
  statements. A dependency outside the problem counts as proposed. Statements on a cycle in the data (which the
  app never creates; an import might) count as proposed and are flagged.
- **Every problem has its theorem** ("Thm 1"), created with the problem, and at launch for problems from before
  Milestone 4. Its text follows the problem statement, one way. Once a Lean result or fidelity review exists for
  that wording, the problem statement can no longer change (invariant 12).
- **What every prompt carries as adopted lemmas:** every statement that is not refuted, not the theorem and not a
  conjecture, with its displayed status in words and why it is held down, for example
  `(sketched; capped by Claim (refuted); depends on a refuted claim: Claim)`. Order: creation time, then label,
  then ID, so the cached prefix is the same on every send. Chosen in the milestone's questions.
- **Promotion** makes a lemma or claim of a run of consecutive steps of one finished attempt (chosen in the
  milestone's questions). It starts from a step's context menu or from the referee's "Promote Step to Lemma…".
  The statement starts as the steps' text, to be rewritten as a statement. The label is the next free "Lem N",
  "Used by Thm 1" is on by default, and the author is the person promoting.
- **Adopt waits for Milestone 7 (Branches)**, chosen in the milestone's questions. Mark Checked and Formalize in
  Lean are shown disabled, naming Milestones 5 and 8: no button sets a status.
- **Labels are unique within a problem** (trimmed, ignoring case), since the graph, the context and exports name
  statements by label. A number is not reused while a higher one exists.
- **A statement's text can be edited,** except the theorem's (edit the problem) and a wording a Lean result or
  fidelity review was given for.
- **Deleting a statement asks first** and says what changes: what used it may show a higher status, a refuted
  claim leaves every prompt, and its Lean result and evidence go with it. Removing one edge does not ask; the
  status changes visibly at once.
- **The inspector is 340 pt wide** (three boxes to a row), chosen in the milestone's questions. The window's
  minimum with it is 1136 pt.
- **The graph's layout.** Statements nothing uses at the top and what they use below (longest path), at most three
  to a row, unconnected statements last. Edges run up from a dependency to the statement using it, between the
  boxes, with the arrowhead at that statement; an edge from a refuted statement is dashed. Each box shows its glyph, label and short
  status, and a mark in words: ✗ uses refuted, ↻ in a cycle, ↓ capped.
- **No schema change.** V1 is unchanged, so the scratch store opened as before.

## 2026-10-17: The data store is scratch until real use

- **Scratch for now.** The store at `~/Library/Application Support/sangaku/sangaku.store` (first created on
  2026-10-17) holds test data only. Schema V1 stays editable.
- **Schema changes ask first.** When a milestone changes the schema so that the existing store no longer opens,
  the store is deleted and started fresh only with explicit approval, never automatically.
- **Real use freezes V1.** Once sangaku is declared in use for real research, V1 is frozen. Every later schema
  change goes into a new `VersionedSchema` with a stage in `SangakuMigrationPlan`, and existing data is kept.
- Reason: until then, editing V1 in place keeps the schema simple and costs only test data.

## 2026-10-17: Milestone 3 architecture and choices

- **Architecture.** The "clean" blueprint, chosen at the milestone's architecture step:
  - `SendPlanner` and `RequestPreparer` are pure. The composer's estimate and the send come from the same
    preparation. A `ReadySend` exists only once every recipient's context was built, against an in-memory copy of
    the fan-out, so a send any recipient would refuse writes nothing.
  - `RequestPreparer` is the one place where a slot becomes a request: provider, model, role prompt, output format.
  - `FanOutRun` is a pure reducer and alone decides when a prover or the referee starts (invariant 4).
  - `ThreadManager` stays the only owner of tasks and of store writes, and carries out the reducer's commands.
  - Reason: the lifecycle (turns, reading output, the referee, the stops, quit, delete) is where invariant 4 can
    break; as a reducer every transition is tested without SwiftData. Milestone 6's alignment request reuses the
    preparer and the output formats.
- **Providers and models.** Anthropic only, and Claude Opus 5.5 only. A second provider and further models wait
  until they are asked for. The slot menu lists the catalog's models; routing already goes through each slot's
  provider. The open decision on further providers stays open.
- **Cost.** Shown, not limited: an input estimate per model and a total, and an output ceiling, the output reserved
  per request at the model's output price. The referee's input is estimated only once the attempts exist. Provers
  that run at once each write the prompt cache; the upper input figure assumes they all do.
- **What makes a fan-out.** Two or more provers, or a referee. Each prover then writes a structured attempt. One
  prover alone writes a prose reply with `prover.md`, as in Milestone 2.
- **Visibility.** Independent provers run at once and never see each other. Shared provers run in letter order,
  one at a time; each later one is built from the store when its turn comes, so it sees the attempts before it.
- **Stop.** A card's Stop ends one attempt; the referee still follows and sees it marked partial. Stop All (⌘.)
  ends everything on the branch and cancels a referee still waiting. "Referee with C" starts the referee by hand
  whenever nothing runs on the branch, also to referee again.
- **What the referee sees.** The branch as it stood when the last attempt was written: nothing said since, so a
  second referee judges afresh. The attempts it judges are marked "to judge", apart from earlier fan-outs' attempts
  by the same letters. Its closing instruction is written in code and recorded verbatim in each request's context
  text.
- **Rule 4.** The newest verdict on an attempt stands; verdicts given at the same instant count as a gap if any is
  one. Two further tightenings were declined: "a verdict on a partial attempt never passes" and "a verdict must
  postdate the step's revisions". (The second was taken up in Milestone 5, in a refined form; see 2026-10-18.)
- **Verdicts fail closed.** An attempt the referee did not judge gets no verdict. An unknown outcome is a gap.
  "Complete" with gap steps listed is a gap, and so is "complete" for an attempt with nothing in it. Several entries
  for one attempt merge into the least trusting. `sawPartialAttempt` is per verdict: the attempt it judges reached
  the referee partial.
- **Structured output.**
  - Requested as `output_config.format` (`json_schema`) beside the effort. The schema is spliced into the body
    verbatim: the encoder's snake-case strategy would rewrite its keywords, and re-serializing would reorder its
    properties. Properties come in the order the model should write them: a step's text before its label and
    confidence; a verdict's attempt, rationale, gap steps, then outcome; the verdicts before the summary.
  - The referee's schema allows only the letters of the attempts it judges.
  - Read whole when a request finished; read as far as it goes (complete steps only) when it ended early. Any
    control character in a string fails the read, since JSON makes one out of a single backslash in `\theta`,
    `\frac`, `\neq`. Unknown confidence labels fail it too.
  - The raw output is always kept (`RequestRecord.rawOutput`), and how it was read is stored
    (`RequestRecord.parseState`: clean, partial, unstructured). Unreadable output is shown verbatim, never typeset.
  - Steps are numbered by position, and each gets a first revision authored by the model's slot (invariant 7).
- **Prompts.** `prover-attempt.md` (version 2) for attempts and `referee.md` (version 1). Tags are by file name
  (`prover-attempt@2`, `referee@1`), so the prose and attempt prompts never collide.
- **Schema V1 edited in place**, still with no store on disk: `RequestRecord.parseStateRaw` and `rawOutput`
  (external storage), and `RefereeVerdict.messageID`, which ties verdicts to the referee message that gave them.
- **Provenance.** A message's header and its label in later contexts take the role from the message's kind and
  the model from its request record, so editing a slot never relabels what it wrote.
- **Slots.** Each toolbar chip is a menu for its role and model. Add Model adds a prover with the next free letter;
  letters are never reused. Formalizer and scout can be assigned but receive nothing until their prompts exist.
  Removing a slot is deferred.
- **Verdict styles** live in `StatusStyle`: complete is drawn as checked by a model (◐), a gap with a dashed delicate
  frame (△), no verdict dotted (–). A gap is never drawn as refuted, and complete never as verified.
- **The referee's actions** (Adopt, Promote step to lemma, Review step by step) are shown disabled, naming their
  milestones in their help and in a caption.
- **Layout.**
  - Attempt cards sit side by side in equal columns of at least 250 pt and stack when the column is narrower.
  - Send names its recipients when there is room and reads "Send" when there is not; the context chips fold into
    one line of text when narrow. The composer never needs more than the workspace's narrowest width, and its
    height holds while typing.
- **Layout additions.** `Services/LLM/Output` (formats and parsers), `Services/LLM/Planning` (selection, preparer,
  planner, reducer), and in `Views/Thread`: `AttemptCard`, `StepRow`, `RefereeMessageRow`, `FanOutBlock`,
  `FanOutHeader`, `ThreadItems`, `ComposerControls` and `MessageParts`.
- **Debug launch flags.** `-SangakuDemoFanOut <text>` sends a fan-out to A and B refereed by C in the demo;
  `-SangakuDemoShared YES` makes it shared.

## 2026-10-17: Window layout on macOS 26

- **The side columns have fixed widths.** The sidebar is 240 pt and the inspector 340 pt (260 pt until
  Milestone 4 widened it for the statement graph), so they cannot be resized for now.
- **The inspector is attached to the workspace column,** not to the split view.
- **The window's minimum is computed from the columns:** 2 × (sidebar + 8) + 300 pt for the workspace, plus the
  inspector when it is shown. That is 796 or 1136 pt wide, by 600 pt high. Showing the inspector widens a
  narrower window.
- **The composer has fixed heights** and is never laid out narrower than the workspace's minimum.
- Reason:
  - On macOS 26 the split view's minimum counts the floating sidebar twice: as a column, and as the workspace's
    inset beneath it.
  - The split view takes a column's minimum height from its content at zero width.
  - A window narrower or shorter than that minimum got a split view of its own, larger size, centred, with both
    side columns and the composer's Send cut off.
  - Fixed column widths keep the minimum predictable.
- Revisit if a later macOS counts floating columns once (the minimum would then only be larger than needed), or
  if the statement graph needs a resizable column.
- **The composer checks whether a key is stored when it appears,** instead of at the first keystroke, so its
  banner never appears mid-typing. The check asks only whether a key exists: it never reads the key and never
  shows a prompt.

## 2026-10-17: Milestone 2 architecture and choices

- **Architecture.** Milestone 2 follows the "clean architecture" blueprint:
  - pure value code for the SSE parser, the Anthropic wire format, `ContextBuilder`, the token estimator, the
    model catalog and prompt parsing;
  - I/O behind two protocols, `HTTPTransport` and `SecretStore`;
  - `ThreadManager` as the only owner of request tasks and of writes to the store;
  - a `ProviderRequest` can only be made from a `BuiltContext`, which only `ContextBuilder` makes, after checking
    the provider policy. Invariant 15 holds by type.
  - Reason: Milestone 3 (several slots, fan-out, referee) and later providers add cases, not restructuring.
- **Models.** Only Claude Opus 5.5 (`claude-opus-5-5`) is offered. Prices are in `ModelCatalog`, as of 2026-10-06.
  An unknown model ID shows an unknown price and window, never a cost of 0.
- **API key.**
  - Entered in a Settings window (⌘,). It is stored as a generic password in the login keychain (service
    `local.sangaku`, account `anthropic-api-key`). There is no data-protection keychain and no entitlements file.
  - Never read at launch. Settings and the composer check only that a key exists (an attributes-only query,
    which never prompts). The provider reads it inside a request, off the main actor.
  - Tests, previews and the fixture use an in-memory store and no network.
- **Signing stays ad hoc for now.** Debug builds ask for Keychain access again after each rebuild. The open
  decision on signing for other Macs stays open.
- **Provider policy.** A new problem allows no provider. The composer offers "Allow Anthropic for This Problem",
  and the problem editor has an Allowed providers section.
- **Replies are prose with LaTeX** (`MessageKind.reply`). Structured steps through JSON-schema output come with
  Milestone 3's attempt cards. The prover prompt already asks for the literal
  `Step n (establishes: …; confidence: …)` labels.
- **Estimates before sending are local.** Nothing leaves the Mac before Send.
  - Tokens are estimated as UTF-8 bytes ÷ 3.2 plus extra for LaTeX markup, so they err high. They are corrected
    by the median ratio of actual to estimated tokens over the last ten requests to the model, clamped to 0.5–2.
  - Input cost is shown as a range, from "stable part read from the cache" to "written to it". Output is shown as
    a price per token; its length is not guessed.
- **Refusals stop and are shown.** No fallback parameter is sent, so no other model answers under a slot's letter.
- **Thinking.** Default effort is high, with a Think menu per message. Thinking is adaptive and not displayed.
- **Schema V1 edited in place**, because no store existed on this Mac. V1 freezes once real research data exists.
  - `Message` gains `derivedFromIDs`.
  - `RequestRecord` gains `answeredModelID`, `estimatedInputTokens`, `cacheWriteTokens`, `usageReported`,
    `stopReason`, `stopCategory`, `errorKind`, `errorMessage` and `finishedAt`. `estimatedCost` becomes optional
    (nil means unknown).
  - `cachedInputTokens` means tokens read from the cache; `inputTokens` is the API's uncached input.
  - This refines the spec's domain table.
- **Invariant 4.**
  - For a request that belongs to an independent fan-out, `ContextBuilder` withholds:
    - the other provers' attempts;
    - every message whose `derivedFromIDs` lead to them (followed to a fixpoint);
    - failing closed, every message another model wrote after the fan-out's request.
  - The referee waits until every attempt has finished or been stopped. It sees every attempt, partial ones
    marked, including attempts with no text or a refusal.
  - A fan-out that is not on the branch is refused.
  - Ordinary replies are not filtered.
- **Invariant 5.**
  - The stable part is six system blocks, always present ("(none yet)" when empty): role prompt, problem,
    notation, adopted lemmas, dead ends, refuted claims. The cache breakpoint is on the last of them.
  - Drop order: older exchanges oldest first, then dead ends, then adopted lemmas, then the latest exchange.
  - Never dropped: the role prompt, the problem, the notation, refuted claims and the message being answered. If
    they alone do not fit, Send is refused with the numbers.
  - Fit is checked with a 10% margin. The model is told when messages were left out. Every drop is recorded and
    shown in the composer and in View context.
- **Adopted lemmas** were empty until Milestone 4; see the Milestone 4 entry for what they hold now.
- **Dead-end text for models** is `reasonForModels`, else `reason`, else "(no reason recorded)"
  (`Branch.textForModels`, which the Branches view will show).
- **A message's outcome is derived, never stored.** The order is: streaming, declined, failed, interrupted
  (including a request that never finished), cut off, ended early, complete. Only a stop reason known to mean
  "finished" reads as complete.
- **Streaming.**
  - Tokens go only to the reply's `MessageStream`, published at most every 50 ms. The reply is written once,
    when the request ends.
  - A save mid-stream keeps a record whose `finishedAt` is unset, which reads as interrupted.
  - Quitting stops live replies and keeps their text. Records left unfinished by a crash are marked when their
    branch loads.
  - The unclosed math at the end of a streaming reply is shown as plain pending text. The finished reply is
    rendered whole, so a delimiter that is really missing still shows as a source chip.
- **Layout additions.** `Services/LLM/{Core,Transport,Anthropic,Secrets,Context}`, `Views/Settings`, and
  `CredentialManager`. The small observables `MessageStream` and `ComposerDraft` also sit in `Managers/`.
- **Debug launch flags.** `-SangakuDemoReplies` (stream a canned answer in the fixture), `-SangakuDemoSend <text>`
  (send one message after launch) and `-SangakuSnapshotDelay <seconds>`.
- **`-SangakuFixtureLive YES`** (debug builds only, added on request on 2026-10-17) opens the example
  in memory with the real Keychain and network, so real prompts can be tried on it.
  - Nothing is saved.
  - Each request is billed.
  - `-SangakuFixture` alone still never reaches the Keychain or the network.

## 2026-10-16: Milestone 1 architecture and conventions

- **Architecture.**
  - Milestone 1 follows the "clean architecture" blueprint:
    - one shared TeX tokenizer;
    - a chain of math tiers whose output (`RenderedMath`) has no case for an approximation;
    - a stable ID and creation date on every model from schema v1;
    - one save path (`SaveScheduler`).
  - Reason: later milestones (thread, fan-out, statement graph, review, merge) build on these seams.
- **People and model slots are referenced by stable ID, not by relationship.** This applies to reviews, fidelity reviews, dismissals, refutation acceptance and referees.
  - Reason: provenance survives deleting or merging a `Person` or `ModelSlot`, collaborator merges resolve by ID, and predicates stay simple.
  - This refines the spec's domain table, which lists "reviewer (person)" without saying how.
- **Stored enums are raw strings with a least-trusting fallback.** An unknown review verdict reads as *unclear*, a referee outcome as *gap*, a citation as *unverified*, and a fidelity verdict as *differs*.
- **Hardened runtime is off in Debug and on in Release.**
  - Reason: the hosted test bundle loads into the debug app, and library validation would refuse it.
- **Preamble import lives in `ProblemManager`** until `ImportService` arrives with the plain-file import (Milestone 9).
- **Colours.** UI chrome (captions, secondary labels) uses the system's hierarchical styles. `secondaryInk` is reserved for mathematics, where it marks math no person has checked.
- **`\color` in a formula.** The formula is set, but its colour is not shown: rendered math takes the surrounding ink, so status colouring stays consistent.
- **Formula corpus sources.** The regression corpus uses only material inside this project (the renderer spike's expressions, the fixture, and generated symbol and command tables). Never manuscripts or other files from outside the development folder.
- **Toolchain.** Xcode 27.1 with Swift 6.4, Swift language mode 6 and a macOS 26.0 deployment target. Builds go through `xcodebuild`. Xcode's MCP bridge (`xcrun mcpbridge`) exists but is not configured.
- **Commands.**
  - New Problem is ⌘N and New Window is ⌥⌘N.
  - ⌘1–4 switch views, ⌥⌘I toggles proof structure, and ⌘⇧B toggles blind mode.

## 2026-10-16: MicroTeX math font stays XITS Math

- Tier 2 keeps XITS Math. The fast path uses STIX Two Math for its symbols and STIX Two Text for letters.
- Reason: STIX Two Math, converted to `.clm2` with FontForge and MicroTeX's `otf2clm.py`, rendered the right glyphs but MicroTeX laid it out badly:
  - `\left| … \right|` was assembled from broken pieces;
  - boxes ending in an italic letter were too narrow, so the letter touched the following word;
  - there was extra space after subscripts.
- XITS Math, which MicroTeX ships prebuilt, showed none of these problems in the spike.
- Revisit if MicroTeX's handling of STIX Two Math's MATH table is fixed.

## 2026-10-16: Math renderer: typographic fast path, MicroTeX, source chips

- **Tier 1.** Simple inline math is set as styled text with TeX's spacing between atoms. This covers 86% of the inline formulas in the test thread.
- **Tier 2.** Everything else goes to MicroTeX: MIT licence, openmath branch, last upstream commit 2024-08-06. It is vendored as a C++17 target behind its C API, and its drawing commands are replayed with CoreGraphics.
- **Tier 3.** A formula neither tier can render shows its LaTeX source in a chip with a warning.
- Changes we carry:
  - In the vendored C++: strict parsing, so unknown commands and environments are errors instead of raw text; and a shim that turns C++ exceptions into error strings.
  - In Swift, before typesetting:
    - amsmath spacing for `\pmod` and `\bmod`;
    - `/` as an ordinary symbol;
    - `\operatorname*` as `\mathop{\mathrm{…}}\limits`;
    - a structural check that turns broken input into a source chip, because MicroTeX would quietly repair it.
- Math font: see the entry above.
- Reason: chosen after the second round of the spike (`Spikes/MathRenderer/RESULTS.md`).
  - Among the candidates it was the fastest and lightest: 22 µs per formula, first formula 16 ms after launch, +13 MB.
  - It covered 78 of 79 test expressions; `CD` is unsupported and reported as an error.
  - It missed no frames at 120 Hz with every formula new and typesetting on the main thread.
  - The fast path makes most math selectable, searchable and accessible, matching how the mockups draw inline math.
  - Alternatives:
    - SwiftMath: 62 of 79 exactly.
    - KaTeX images: +75 MB WebKit process, about 0.5 s cold.
    - MathJax in JavaScriptCore: about 1 ms per formula and +36 MB, and it stutters at 120 Hz.
- Accepted risks:
  - Upstream is quiet, so we maintain the vendored copy.
  - It keeps global state, so it is used from one actor only.
  - Coverage is proven on a small corpus, so the app keeps a regression corpus that grows toward 1000+ formulas.

## 2026-10-16: Math rendering must be fast and light

- KaTeX images, rasterized in a hidden web view, are rejected.
- Reason: rendering must be fast and light. KaTeX images cost an extra 75 MB WebKit process and about 0.5 s on a cold start.
- Small design changes are acceptable in service of this.

## 2026-10-16: Name and bundle ID

- The app is **sangaku**, always lowercase in the UI, menus and bundle. Bundle ID `local.sangaku`.
- Swift type names keep the language's capitalization (`SangakuApp`).
- Reason: a sangaku is a geometry problem hung as a tablet in a temple, offered to be checked by others.
- The bundle ID only needs to be unique on this Mac, since the app is not on the App Store.
- Changing it later means moving Keychain items, so change it before real research data goes in. The store lives in Application Support/sangaku regardless of the bundle ID.

## 2026-10-16: First LLM provider

- Anthropic (Messages API) first. Other providers come later behind the same `ModelProvider` protocol.
- Reason: independent fan-outs work best across model families, so a second provider is the natural next step once fan-out lands.

## 2026-10-16: Distribution outside the Mac App Store

- The app is not published on the Mac App Store, for now. App Sandbox is off, so it can launch locally installed `lake`, `lean` and `gap`.
- Still open: Developer ID and notarization, needed only to run the app on another Mac.
- Reason: no App Store release is planned. On this Mac, development signing with a stable certificate is enough.

## 2026-10-16: Renderer spike may fetch SwiftMath and KaTeX

- SwiftMath (MIT) and KaTeX (MIT) may be downloaded for the throwaway spike in `Spikes/`. Adding either to the app still needs the renderer decision.
- Reason: the spec requires spiking both before committing.

## 2026-10-16: Spec revisions adopted

All three groups of revisions from the review of the spec against the mockups were adopted.

- **Trust model.**
  - `formallyVerified` requires an axiom check (only `propext`, `Classical.choice`, `Quot.sound`) and a person's fidelity ✓ that the Lean statement matches the informal one. Reason: "no errors, no `sorry`" passes `axiom h : False` and mis-stated theorems.
  - Status is capped by dependencies, and `uses` is acyclic. Reason: rules 3 and 4 let a theorem show "checked" while resting on an unchecked or refuted lemma.
  - An open ✗ or ? blocks until the step is revised or the objection is dismissed with a reason. Reason: under "the latest review is a ✓", one reviewer's ✓ silently overrode another's ✗.
  - New `RefereeVerdict` model. Reason: rule 4 and the verdict chips had nothing to read from.
  - The fixture's AI-use statement must match its 4-of-6 review state. Reason: the Review mockup's text overclaims, against invariant 8.
  - Model-written code runs only after a person clicks Run, sandboxed through `ToolRunner`. Reason: with App Sandbox off, a subprocess can read the home folder and reach the network.
- **Engineering.**
  - One shared Lean workspace with Mathlib (instead of one Lake project and one Mathlib copy per problem), checked with `lake env lean --json`.
  - Steps are requested as JSON-schema structured output.
  - Context puts its stable part first, for prompt caching, and shows a cost estimate.
  - Every request writes a `RequestRecord`, which View context displays.
  - The renderer spike tests inline math in wrapping prose.
- **Features.**
  - Kerodon-style manuscript export through the hashtag kit.
  - A plain-file copy of each problem.
  - v1 collaboration by sharing and merging that copy, with a `Person` model.
  - LaTeX preamble and draft import.
  - A per-problem provider policy.
