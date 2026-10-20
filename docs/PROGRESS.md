# Progress

Appended at the end of each milestone.

## 2026-10-16: Before Milestone 1

- Exported the four mockup screens to `Design/` (`1-thread.png`, `2-compare.png`, `3-review.png`, `4-branches.png`) and moved the canvas there. The screenshots were rendered offline, so they use the system font instead of IBM Plex.
- Reviewed the spec against the mockups. The adopted revisions are listed in `docs/DECISIONS.md`.
- Settled the name (sangaku), the first provider (Anthropic) and distribution outside the App Store.
- **Renderer spike, round 1** (`Spikes/MathRenderer/`):
  - SwiftMath parsed 41 of 79 test expressions and KaTeX 79 of 79.
  - One web view per row cost about 36 MB and 2–3 s per row, so it was ruled out.
- **KaTeX rasterized into native text** worked, but was rejected as neither fast nor light enough.
- **Round 2** added MicroTeX (vendored C++), MathJax 4 in JavaScriptCore and a typographic fast path (`Spikes/MathRenderer/RESULTS.md`, `results/comparison.png`).
- **Decided:** the typographic fast path, then MicroTeX, then LaTeX-source chips for anything unrenderable.

## 2026-10-16: Milestone 1, Shell

### What was built

- **Project.**
  - A hand-written `sangaku.xcodeproj` with synchronized folders: app target `sangaku` (`local.sangaku`) and hosted test target `sangakuTests`.
  - Shared settings live in `Config/Base.xcconfig`. A Team ID goes in a gitignored `Config/Local.xcconfig`.
  - MicroTeX is a local Swift package in `Vendor/MicroTeX/`, with its changes listed in `PATCHES.md`.
- **Data.**
  - SwiftData schema v1 with all 19 domain models: CloudKit-compatible, a stable ID and creation date on each, and an (empty) migration plan.
  - The store is at `~/Library/Application Support/sangaku/sangaku.store`, saved through a debounced `SaveScheduler`.
  - A failed save shows a banner and retries.
  - Quitting with unsaved changes asks first.
  - A store that will not open is explained and left untouched.
- **Math** (`Services/Rendering`):
  - the shared TeX tokenizer;
  - the macro parser and expander (caps against runaway definitions; skipped definitions reported with line and reason; CRLF files handled);
  - the structural validator;
  - tier 1 (typographic text with TeX's spacing between atoms);
  - tier 2 (the MicroTeX bridge: strict parsing, a decoder that fails instead of drawing part of a formula, drawing that is safe on any thread);
  - `MathRenderer` with a generational cache.
  - `MathText` in `Views/Components` composes prose, inline and display math, and source chips with their reasons, all read sensibly by VoiceOver.
- **Status.**
  - `StatusStyle` (border pattern, fill, ink, glyph and label; Differentiate Without Color and Increase Contrast respected).
  - `StatusRules`, the spec's rules 1–6 for a statement's own status, with the dependency cap left to Milestone 4.
  - Colour tokens are in the asset catalog with dark variants.
- **Window.**
  - `NavigationSplitView`: the sidebar (problems, branches, notation registry), the workspace (pinned problem card in its status ink, and placeholders for Thread, Compare, Review and Branches), and the proof-structure inspector (placeholder plus status legend).
  - Toolbar: the view switcher and read-only model-slot chips.
  - Commands: ⌘N, ⌥⌘N, ⌘1–4, ⌥⌘I and ⌘⇧B.
  - Sheets: problem editor, convention editor and preamble import, each with live math preview.
  - The app starts empty. Each window opens on the most recent problem.
- **Fixture.**
  - `Preview Content/PreviewFixtures.swift` holds the mockups' example (Theorem 1, attempts A and B, Referee C, the 4-of-6 review state, Lean results, the GAP sweep, dead ends, citations).
  - Previews use it through `#Preview(traits: .fixture)`.
  - Debug builds launched with `-SangakuFixture` open it in memory, and `-SangakuSnapshot <path>` writes a PNG of the window.

### Tests

98 tests in 21 suites (Swift Testing), all passing:

- **Schema:** the CloudKit lint, cascades and fallbacks.
- **TeX:** the tokenizer, macros and preamble parsing.
- **Rendering:**
  - tier 1, including the declined cases;
  - MicroTeX's strict parsing, rewrites and text fallback;
  - the decoder's failure cases;
  - the validator;
  - the renderer's tier routing and invariant 16;
  - segmentation and accessibility.
- **Status:** the style, the rules, and invariants 1, 2, 3, 6, 11 and 12 on the fixture.
- **Managers:** saving, conventions, import, and the window flows.
- **Formula corpus:** 81 recorded rows plus generated tier-1 and command sets.
- **Preview smoke tests** that render the main views offscreen.

### Review

Three reviews covered trust invariants, correctness, and conventions. All high- and medium-severity findings were fixed, with tests:

- **Tier 1 output:** a stray "*" for `\operatorname*`, and literal `_`/`^`/`$` inside `\mathrm`/`\text`.
- **Status rules:**
  - dismissals now need a person and a reason;
  - objections block whoever raised them;
  - a Lean result counts only if it ran and its messages are readable.
- **Pinned card ink.**
- **Silent save failures.**
- **CRLF preambles.**
- **The problem editor** now works from every view.
- **Create and delete flows:** each now has a single path.
- **VoiceOver** speech for scripts and source chips.
- **The MicroTeX text-layout ascent sign.**
- **Deleting a convention** now takes effect immediately.
- **Smaller fixes:**
  - duplicate list IDs;
  - sheet placement;
  - definitions inside formulas are refused;
  - formula drawing is safe off the main thread.

### Deferred

- **Formula corpus growth.** The corpus has 81 recorded formulas plus the generated sets; the target is 1000+. Grow it from material inside this project in each milestone.
- **Hovering a symbol inside rendered math to show its registry entry.** It needs a custom text layout that maps glyphs back to symbols; planned with Review (Milestone 5). Sidebar notation rows already show their entry on hover.
- **`\dots` glyph by context.** amsmath picks centred or low dots from the following symbol; tier 1 always uses low dots.
- **Display-style `\pmod` spacing** (18mu) in the tier-2 rewrite; inline spacing is used everywhere.
- **Tier-2 baselines** can sit up to 1 pt high, because image heights are rounded up while the descent is not.
- **Parsing and file reading in the import sheet and the convention editor** move to `ImportService` with Milestone 9.
- **UI tests for the keyboard shortcuts.** They are wired in `SangakuCommands`, but no test exercises them.
- **A C++ leak.** If MicroTeX's `getDrawingData` throws, its few-KB buffer leaks in upstream code.
- **Window check.** The window was checked through offscreen renders. The macOS 26 sidebar and inspector glass cannot be captured from this setup, so a look at the running app is still due.

### Next

Milestone 2: one model. The thread with Anthropic, streaming and cancel, the composer with LaTeX preview, `ContextBuilder` with its tests, `RequestRecord` with View context, a cost estimate, and the per-problem provider policy.
- Needs: an Anthropic API key, stored in the Keychain.
- Needs: a stable signing identity (a Team ID in `Config/Local.xcconfig`), so Keychain access is not re-prompted after every build.

## 2026-10-17: Milestone 2, One model

### What was built

- **LLM layer** (`Services/LLM`):
  - `ModelProvider` streams `ProviderEvent`s. The Anthropic adapter covers the Messages API over URLSession: SSE
    streaming, cache breakpoint, effort, HTTP and mid-stream errors, and refusals.
  - Below it: an incremental SSE parser, the wire format as pure functions, an `HTTPTransport` seam, and a provider
    registry.
  - Above it: `ModelCatalog` (Opus 5.5 and its prices), a local token estimator with calibration, and versioned role
    prompts (`Resources/Prompts/prover.md`).
  - `SecretStore` keeps the API key in the login keychain. Tests, previews and the fixture use an in-memory store.
- **Context.**
  - `ProblemSnapshot` copies a problem and branch into values on the main actor.
  - `ContextBuilder` is pure. It builds the six-block stable part with one cache breakpoint, then the conversation.
    It applies the provider policy (invariant 15), keeps independent attempts apart and makes the referee wait
    (invariant 4), and drops in a defined order that it records and shows (invariant 5).
- **Thread.**
  - `ThreadManager` sends, streams, stops and finishes requests. Streamed text goes only to a per-reply
    `MessageStream`; the reply and its `RequestRecord` are written once when the request ends.
  - Quit, deleting a problem mid-stream, and records left unfinished by a crash are all handled.
  - Message rows show:
    - author and model;
    - the "Proposed" status (provisional ink and frame);
    - stopped, declined, failed, cut-off or ended-early outcomes as a glyph and words;
    - usage and cost, with View context.
- **Composer.**
  - LaTeX source with a live MathText preview, the Think menu, and Send (⌘↩) or Stop (⌘.).
  - Context chips with a fit label, an estimate of the input and its cost range, and the output price.
  - Banners for the provider policy and a missing API key.
  - The draft is kept per branch for the session.
- **View context** shows the text sent with the cache breakpoint marked, the parameters, the usage (input, cache
  write, cache read, output), the cost, how the request ended, and what was left out.
- **Settings** (⌘,) stores, replaces and removes the Anthropic API key. **Provider policy:** new problems allow
  nothing; the composer and the problem editor allow a provider. The toolbar chip names the slot's model.
- **Schema V1**, edited in place (no store existed): `Message.derivedFromIDs`, the new `RequestRecord` fields,
  and `MessageKind.reply`.
- **Fixture.** Slot A now uses `claude-opus-5-5`. A plain exchange with A was added (complete, stopped and failed
  replies, with their request records), and the referee and compute messages carry derivation links.
  `-SangakuDemoReplies` streams a canned answer, so streaming can be tried without an API key.

### Decisions

Recorded in `docs/DECISIONS.md` (2026-10-17):
- Opus 5.5 only; the API key entered in a Settings window; signing stays ad hoc; new problems allow no provider.
- Prose replies; local estimates; refusals shown without a fallback; high effort by default.
- The invariant 4 and 5 rules, the schema additions, and the layout additions.

### Tests

176 tests in 33 suites (Swift Testing), all passing. Milestone 2 added 78:
- **Catalog and estimator:** prices, unknown models, calibration.
- **Prompts, outcomes and the streaming tail:** the prompt library, message outcomes, the streaming tail and
  invariant 16.
- **SSE parser:** every split point, CR/LF, blank-line and no-blank-line framing.
- **Anthropic wire format and provider:**
  - the request body (one breakpoint, no thinking or sampling settings, no prefill);
  - the API key in the header only;
  - event decoding, refusals and stop reasons;
  - mid-stream and HTTP errors, Keychain failures, a truncated last line, cancellation.
- **`ContextBuilder`:**
  - invariant 15;
  - invariant 5 content, toggles, and a drop-order sweep over every budget;
  - invariant 4: siblings, transitive derivation, the fail-closed backstop, shared fan-outs, the referee and
    textless attempts, a fan-out not on the branch;
  - turn mapping.
- **`ThreadManager`:**
  - the stream writes nothing to the store until it ends, and a save mid-stream reads as interrupted;
  - Stop, errors, refusal, policy, a missing API key, a busy branch;
  - drops recorded end to end, and the refusal when the essentials do not fit;
  - deleting a problem mid-stream, quit, orphans, the plan and calibration, an unknown model.
- **Credentials and wiring:**
  - `MessageStream`'s throttle;
  - credentials (nothing read at launch);
  - the in-memory app stays offline;
  - the API key is never stored.
- **Preview smoke tests:** the thread, message rows in every state and in dark mode, the composer, View context,
  Settings.

### Review

Three reviews (trust invariants, correctness, conventions) found no high-severity issue. All 8 medium and 17 low
findings were fixed, with tests where they apply:
- **Composer.**
  - The estimate is now tied to the problem and branch (it could show the previous problem's chips and cost).
  - Statement and model edits refresh it.
  - Every refusal is shown inline.
- **Referee and fan-outs.**
  - The referee now hears about attempts with no text, or that were declined.
  - A fan-out that is not on the branch is refused.
- **Errors and stop reasons.**
  - A Keychain failure is reported as such, with a Settings link (it read as a network error).
  - Unknown stop reasons no longer read as complete.
  - A truncated last SSE line after the stop reason still finishes the reply.
- **Orphaned and stopped replies.** An orphaned reply no longer claims its text was kept. A stopped reply shows
  "output unknown" instead of a count.
- **Typing.** `send` throws its refusal. Local stop reasons and the errors that need Settings are typed, not
  repeated strings.
- **Accessibility.** Reduce Motion for the thinking pulse; row labels; `.updatesFrequently` while streaming. Model
  replies show the "Proposed" glyph and label.
- **Conventions.**
  - The wire structs use camelCase with key strategies.
  - Neutral banners instead of the confidence colours.
  - `#Preview`s for the new views.
  - File placement (`Branch.textForModels`, `UsageFormat`).
  - No force-unwraps in the new tests; one code comment reworded.
- **Thread view.** Rows keyed by stable ID, and the thread scrolls to the newest message and to the end of a reply
  that finished.

### Deferred

- **A live request against Anthropic has not been made.** Everything up to the network is tested, and the
  fixture's demo stream was checked in the running app. Still to try with a real API key:
  - the first Keychain prompt;
  - one reply, Stop, and View context;
  - Replace and Remove in Settings.
- **Signing.** Ad hoc signing makes the Keychain ask again after every rebuild, until a stable certificate is set
  up.
- **`ThreadManager`'s estimate logic** (plan, calibration) could move into a pure `SendPlanner` service.
- **`URLSessionTransport` cancellation** is tested only through a fake transport. Whether cancelling closes the
  real connection promptly is unverified.
- **Long replies.** A streaming reply is re-typeset whole about 20 times a second; very long replies may need the
  settled paragraphs split off. The plan is rebuilt on the main actor after each pause in typing.
- **Tab in the composer** inserts a tab, so Tab does not move focus out of the editor (as in the problem editor).
  ⌘↩ sends.
- **Prose right after display math** starts with a space (`MathText`); changing it touches the renderer.
- **Drafts last for the session.** One request per branch at a time. A failed reply has no Retry; the message is sent
  again.
- **Only the stable part is cached.** The conversation has no second cache breakpoint.
- **Window check.**
  - Snapshots of the running window do not capture its background (the macOS 26 glass). People's messages look
    faint in them, though offscreen renders in both modes are correct.
  - A look at the running app in light and dark mode is still due.
- **Spec drift to reconcile.** The toolchain line (Xcode 27.1, Swift 6.4), the managers' isolation
  (they rely on default `MainActor` isolation rather than an explicit `@MainActor`), and the domain table's new
  fields (recorded in `docs/DECISIONS.md`).

### Next

Milestone 3: fan-out:
- model slots and roles;
- independent and shared visibility;
- the referee pass, including stopped attempts;
- `RefereeVerdict` and verdict chips;
- structured steps through JSON-schema output (prover prompt version 2).

`RequestPurpose.referee`, the invariant 4 rules, `derivedFromIDs` and `partialAttemptIDs` are already in place.

## 2026-10-17: Layout fixes after Milestone 2

Two bugs reported from the Milestone 2 build (`-SangakuFixture`):
1. In a window that was not maximized, the sidebar and the inspector were cut off midway.
2. The composer grew while typing until Send fell below the window.

### Causes, measured in the running window

- **The split view kept its own minimum size and was centred in the window,** cutting off both sides (and the
  top and bottom). It was 1289 pt wide at every window width from 920 to 1280 pt, and 1020 pt tall in a 652 pt
  window.
- **Horizontally**, two things added up:
  - macOS 26 counts the floating sidebar twice in the split view's minimum: as a column, and as the workspace's
    inset beneath it.
  - The workspace had wide fixed rows: the context chips needed about 600 pt.
  - With the inspector attached to the whole split view, its width was counted twice as well.
- **Vertically**, AppKit takes a column's minimum height from its content at the smallest width it offers. At
  zero width the composer's "No API key" banner and its chips wrapped a character per line, so the composer
  alone needed about 655 pt.
- **The composer also changed height while typing.** The editor grew from 60 to 160 pt, the preview appeared at
  the first keystroke and then grew with every line, and the key banner appeared at the first keystroke.

### Fixes

- **Composer.**
  - Fixed heights for the editor (68 pt) and the preview (54 pt), each scrolling inside.
  - The preview is always shown, and scrolls to its end.
  - The editor's hint is now a placeholder in the editor.
  - The estimate reserves its two lines.
  - The context chips wrap (`FlowLayout`), and banners stack when narrow.
  - The key check runs when the composer appears; it asks only whether a key exists, so it never prompts.
  - The composer is never offered less than the workspace's minimum width, so its height stays bounded at any
    proposal.
- **Columns.**
  - The sidebar (240 pt) and the inspector (260 pt) have fixed widths.
  - The inspector is attached to the workspace column.
  - The sidebar's notation actions and the inspector's header stack when narrow.
- **Window.** The minimum is computed from the columns as macOS 26 counts them:
  2 × (240 + 8) + 300 = 796 pt without the inspector, and 1056 pt with it, by 600 pt high
  (`.windowResizability(.contentMinSize)`). Showing the inspector in a narrower window widens the window.
- **Checked in the running app** at 700 (clamped), 1056, 1100, 1200, 1300 and 1440 pt wide and 600–800 pt high,
  with the inspector shown, hidden, and shown again after shrinking. The split view now fills the window exactly
  in every case. At the minimum size, with a 30-line draft, the whole composer and Send are visible.
- **Tests.** Five layout tests, 181 tests in total:
  - the thread at a zero-size proposal fits a minimum-size window (the vertical bug);
  - the window minimum and its parts;
  - the side columns' content fits their widths;
  - every workspace row fits the content minimum;
  - the composer's height is the same for an empty, a one-line and a 60-line draft.
- **Debug tools.**
  - `-SangakuFixtureLive YES` opens the example in memory with the real Keychain and network, to try real
    prompts on it. Nothing is saved, and each request is billed.
  - `-SangakuWindowSize <w>x<h>[@<s>]` resizes the window after launch.
  - `-SangakuToggleInspector <s>,<s>…` toggles the inspector at those times.
  - `-SangakuDemoDraft <text>` fills the draft.
  - The `-SangakuSnapshot` report (`<path>.layout.txt`) lists the window size and every split view's frame in
    window coordinates. The glass columns do not draw into the PNG, so this report is how column clipping is
    checked.
  - Give every flag a value (`-SangakuFixture YES`). A flag without one swallows the next flag; the leftover
    path is then opened as a document and no window appears.

### Deferred

- **The minimum-width formula is empirical.** It encodes how macOS 26 counts floating columns; a later macOS may
  count them once, which would only make the minimum larger than needed. The side columns cannot be resized
  until the formula can follow their widths.
- **Resizing the window does not keep the thread scrolled to its end;** new messages and finished replies do.
- **A display formula wider than the workspace** still sets a minimum width (`MathText` draws it as a
  fixed-width image).

## 2026-10-17: Milestone 3, Fan-out

### What was built

- **Planning** (`Services/LLM/Planning`, all pure):
  - `SendSelection` holds the recipients, the visibility and the referee, read against the slots at send time.
  - `RequestPreparer` is the one place where a slot becomes a request: its provider, model, role prompt, output
    format and context.
  - `SendPlanner` makes the composer's estimate and the send from the same preparation. A `ReadySend`, which only
    it makes, exists only once every recipient's context was built, against an in-memory copy of the fan-out.
    A send any recipient would refuse writes nothing.
  - `FanOutRun` is a reducer: events in, commands out. It alone decides when a prover or the referee starts.
- **Structured output** (`Services/LLM/Output`):
  - JSON schemas for attempts and for the referee's verdicts, sent as `output_config.format` exactly as written,
    with their properties in the order the model should write them.
  - `AttemptParser` reads an attempt whole, or, for one that ended early, the steps complete so far. Any control
    character in a string fails the parse: JSON turns a single backslash in `\theta`, `\frac` or `\neq` into one.
  - `RefereeParser` and `VerdictMapper` read the verdicts and fail closed.
  - Parsing runs `@concurrent`; the raw output is always kept on the request record.
- **`ThreadManager`** carries out the plan and the reducer:
  - One store change per send. Independent provers start at once; shared ones take turns, each rebuilt from the
    store when its turn comes, so it sees the attempts before it.
  - An attempt or a referee stays live until its output has been read, so nothing sees it half-written.
  - The referee starts after the last attempt has ended and been read. A card's Stop keeps it waiting; Stop All
    cancels it; "Referee with C" starts it by hand, again if wanted.
  - Quit reads what arrived at once and starts nothing; deleting a problem forgets its runs.
- **Context.** The referee sees the branch as it stood when the last attempt was written, and the attempts it is to
  judge are marked "to judge". Later models hear a referee's verdicts. A fan-out's prompt stays in the exchange
  being answered. Messages are labelled with the role they were written in.
- **Status.** Rule 4 now takes the newest verdict on each attempt; a tie counts as a gap. Verdict styles live in
  `StatusStyle`: complete is drawn as checked by a model, a gap is never drawn as refuted.
- **Thread.**
  - A fan-out is one item: the prompt; a header ("2 independent attempts · both finished"); who could see whom;
    the referee's state; the attempt cards side by side, stacked when narrow; and the manual referee control.
  - Attempt cards: numbered steps with what each establishes and a confidence chip, a gap mark from the standing
    verdict, live steps while streaming, unreadable output shown verbatim, outcome, cost and View context.
  - Referee messages: a verdict chip per attempt, the summary and each rationale, and Adopt, Promote step to lemma
    and Review step by step, disabled, naming Milestones 4 and 5.
  - Message headers take the role from the message's kind and the model from its request record, so editing a
    slot never relabels history.
  - View context shows the output format, how the output was read, and the raw output.
- **Composer.** A toggle per slot (only provers receive), Independent or Shared, "Then: referee with", Think; an
  estimate per model with a total and an output ceiling, and the details in a popover; "Send to A, B, then C",
  shortened to "Send" when narrow; Stop All during a fan-out.
- **Toolbar.** Each slot chip is a menu for its role and model; Add Model adds a prover with the next free letter.
- **Fixture and demo.** Slots B and C use Opus 5.5. The attempts and the referee have request records built by the
  real `ContextBuilder`. The demo transport answers attempts and verdicts in the structured formats.
  `-SangakuDemoFanOut <text>` sends a fan-out to A and B refereed by C; add `-SangakuDemoShared YES` for a shared
  one.

### Decisions

Recorded in `docs/DECISIONS.md` (2026-10-17): Anthropic and Opus 5.5 only; cost shown, not limited; what makes a
fan-out; shared means in turn; Stop and the referee; what the referee sees; rule 4; the structured formats and the
parse rules; the prompt files and their tags; the schema additions; the slot menus; the layout additions.

### Tests

246 tests in 43 suites (Swift Testing), all passing. Milestone 3 added 64:
- **Parsing:** clean, every truncation point, the control-character guard (parameterized over `\theta`, `\frac`,
  `\beta`, `\rho`, `\neq`, `\nmid`, `\tau`, `\binom`), off-schema output, the referee's output, fail-closed mapping.
- **Formats and wire:** closed schemas, the referee's letters, the schema on the wire byte for byte, the prompts and
  their tags.
- **`FanOutRun`:** parallel, in turn, stopping a waiting prover, Stop All, quit, the referee by hand.
- **Selection, plan and header:** recipients, toggling, totals, header words.
- **`ThreadManager` end to end:** the send, a refused recipient, steps and their revisions, the referee after every
  attempt (with the last one read as steps), a card's Stop, Stop All and the referee by hand, shared turns,
  stopping a waiting prover, failed and cut-off attempts, unreadable attempts and verdicts, a policy revoked
  mid-run, refereeing again afresh, prose versus fan-out, quit, delete, slot edits and provenance.
- **Through the wire:** a demo fan-out read as steps and verdicts; invariant 1 on the example (a full run changes no
  status and no review).
- **Context and status:** the referee's cut-off, two fan-outs on a branch, labels by kind, the prompt kept with its
  attempts, rule 4 newest and ties, verdict styles, confidence never changing status.
- **Layout and previews:** cards stack, the send bar and the composer with a five-recipient plan fit the narrowest
  column and a window of the minimum height, smoke renders of the fan-out, the cards in every state and the
  composer.

### Review

Three reviews (trust invariants, correctness, conventions). The correctness and trust reviews found no
high-severity issue; the conventions review found one. As decided after the review, all findings were fixed except three
(see Deferred):
- **High.** Send's label grew with the recipients and could widen the composer past the narrowest column. It now
  shortens to "Send"; the estimate row was split out (`SendBar`) and is measured with a real plan.
- **Medium.**
  - The referee's context is cut at the fan-out's last attempt, and the attempts it judges are marked "to judge".
  - A verdict on an attempt with nothing in it is never "complete".
  - The header says the referee refereed only when it gave verdicts.
  - The schema is sent verbatim: a step's text before its label and confidence, reasons before outcomes.
  - Prompts are tagged by file (`prover-attempt@2`), so the prose and attempt prompts never collide.
  - Stop reads Stop All during a fan-out; steps have context menus; the new views have previews; more tests.
- **Low.** A later shared prover records when it was sent; a stale live parse no longer overwrites a newer one; View
  context shows the raw output; unreadable output is always shown verbatim; shared row parts moved to
  `Views/Thread/MessageParts.swift`; the recipient rule moved to `SendSelection`; the busy state is read once; the
  disabled actions name their milestones in a visible caption; the slot menu has Role and Model sections;
  `replySlot` was removed.

### Checked in the running app

With `-SangakuFixture YES -SangakuDemoReplies YES -SangakuDemoFanOut …`, at 1440×900, 1280×860, 1200×760,
1056×652 (inspector shown) and 796×600 (inspector hidden): the split view fills the window in each case; attempts
stream side by side with live steps; the referee follows with its chips and gap marks; a shared fan-out runs in
turn; at the minimum size the composer's controls wrap, the context folds to one line, and Send stays in view.

### Deferred

- **No live fan-out against Anthropic yet.** `output_config.format` with adaptive thinking and an effort has been
  tested only up to the network. Try one with `-SangakuFixtureLive YES` (billed), and watch how often the
  control-character guard rejects real output.
- **The toolbar's slot menus were not seen in the running window.** The snapshot tool cannot capture the macOS 26
  toolbar; the menus are covered by the build and by `ProblemManager` tests only.
- **A cancelled quit leaves fan-outs stopped.** Quitting stops every request before the save check; choosing Don't
  Quit afterwards leaves the attempts stopped and the referee cancelled ("Referee with C" restarts it). Replies
  behaved the same in Milestone 2.
- **A compute cell's header falls back to its slot's current role** (compute cells have no role of their own).
- **Per-model cost is in the details popover;** the composer shows the totals.
- **Slot removal.** A slot cannot be removed yet; letters are never reused.
- **Slots D and later share the grey colour** (`coauthor`); the letter tells them apart.
- **Spec drift to reconcile** (with Milestone 2's): `RequestRecord.parseState` and `rawOutput`,
  `RefereeVerdict.messageID`, the prompt files `prover-attempt.md` and `referee.md`, and the folders
  `Services/LLM/Output` and `Services/LLM/Planning`.

### Next

Milestone 4: structure. Promote a step to a lemma, `StatementGraph` with derived status and the dependency cap, and
the inspector's DAG. The referee message's Adopt and Promote step to lemma actions become live then.

## 2026-10-17: Milestone 4, Structure

### What was built

- **Status with the cap** (`Model/Values`, all pure):
  - `StatusDerivation` derives every statement's displayed status: the lowest of its own and the displayed status
    of what it uses. A refuted dependency lets only `sketched` through and is reported through any number of
    statements. Iterative, so a long chain cannot exhaust the stack; a cycle in the data fails closed to proposed.
  - `UsesGraph` finds the cycle an edge would close, with its path, and what a statement may still use.
  - `StatementGraphState` holds a problem's statements as values: what each uses and is used by, the steps it came
    from, its own and displayed status, and why it is held down, in words for people and for models.
  - `StatementLabels` (next free label, headings, step ranges) and `PromotionDraft` (the promote sheet's choices).
- **`StatementGraph`**, the only writer of promoted statements and edges: promote, add and remove a use (a cycle is
  refused with its path), edit a label or text, delete (detached first). Every refusal changes nothing.
- **The theorem.** `ProblemManager` gives every problem its theorem ("Thm 1"): with a new problem, and at launch
  for older ones. Its text follows the problem statement. The problem editor locks the statement once a Lean
  result or fidelity review exists for that wording.
- **The pinned card** shows the theorem's displayed status and, when it is held down, why.
- **The proof-structure inspector** (340 pt):
  - The graph: boxes by layer, three to a row, framed in their displayed status with glyph, label, short status
    and a mark (✗ uses refuted, ↻ in a cycle, ↓ capped); edges routed between the boxes, the selected
    statement's edges emphasised, an edge from a refuted statement dashed.
  - The selected statement: its heading and text, status with own status and the reasons, Uses (remove, Add
    Dependency offering only what closes no cycle), Used by, delicate steps, author; Mark Checked and Formalize in
    Lean disabled, naming Milestones 5 and 8; Edit and Delete.
  - The editor sheet and the delete confirmation, which says what changes.
  - The status legend and a legend of the marks.
- **Promotion from the thread.** "Promote to Lemma…" in the context menu and VoiceOver actions of every step of a
  finished attempt, and the referee's "Promote Step to Lemma…". The sheet chooses the attempt, the run of steps,
  lemma or claim, the label, the statement with a live preview, what it uses, and "Used by Thm 1". The new
  statement is selected in the inspector.
- **Context.** Every prompt carries the adopted lemmas with their displayed status and reasons, in a fixed order.
- **Referee message.** Promote works; Adopt now names Milestone 7, Review Step by Step Milestone 5.
- **Fixture.** The theorem comes from `createProblem`. Lem 5 (verified in Lean, capped by Lem 3 and Lem 4), Lem 6
  (checked by a person, capped by the refuted Claim) and Lem 7 (through Lem 6) show the cap. Statements have fixed
  creation times.

### Decisions

Recorded in `docs/DECISIONS.md` (2026-10-17): the architecture, the cap, the theorem per problem and its lock, what
adopted lemmas are, promotion of a run of steps, Adopt in Milestone 7, unique labels, editing and deleting, the
inspector's width and the graph's layout, no schema change. The window-layout entry has the new widths (inspector
340 pt, minimum 1136 pt). The spec's build order lists Adopt under Milestone 7.

### Tests

298 tests in 52 suites (Swift Testing), all passing. Milestone 4 added 52:
- **The cap (invariant 13):** the full table of own and dependency statuses, a refuted dependency for every own
  status, refuted stays refuted, transitive reporting, the cap read from a dependency's displayed status, binding
  dependencies named, a missing dependency, cycles (self, two, three, below a cycle), a 10,000-statement chain, and
  200 seeded random graphs against a recursive reference.
- **The cycle check:** paths, shortcuts, candidates.
- **The example:** every statement's own and displayed status; a refutation by a person versus under a model's ID;
  a theorem verified in Lean still capped; a newer gap verdict lowering everything resting on the attempt.
- **Observation:** views reading the graph are told about a new verdict and a new review (each linked from its own
  side), a dismissal, an edge and a refutation.
- **`StatementGraph`:** promotion (author, step authors untouched, sources, uses, used by the theorem, status
  derived), a gap attempt making a sketched lemma that caps the theorem, every refusal changing nothing, edges and
  cycles, editing and the locks, renaming the theorem whatever its whitespace, the problem statement locked by a
  Lean check, deletion notes, a deleted statement, deleting a problem whose statements use each other.
- **Context (invariant 5):** which statements are sent, their notes, a capped lemma never described by its own
  status, the order independent of the snapshot's.
- **Invariant 1 end to end:** a whole fan-out and referee pass changes no statement, text, edge or status.
- **Layout:** placement of the example, wrapping, cycles; every edge starts on its dependency, ends on its user, runs
  horizontally and vertically, passes through no other box and shares no horizontal run; the marks, short labels and
  headings; the inspector fits 340 pt; smoke renders of the inspector (light and dark), the promote sheet and the
  editor.

### Review

Three reviews (trust invariants, correctness, conventions). None found a high-severity issue. As decided after the
review, the medium findings and the cheap low ones were fixed, with tests:
- **Medium.**
  - Renaming the theorem was refused when the problem statement ended in whitespace; text is now compared trimmed.
  - Editing the problem statement bypassed the lock on a wording checked against Lean; the problem editor now
    refuses and says why, and launch never overwrites a locked theorem.
  - The delete confirmation now says when a refuted claim leaves every prompt and when Lean results and evidence go
    with the statement; its wording moved to `StatementGraphState` and is tested.
  - The explanation lines and the marks are drawn by one view (`StatusExplanationLines`, `StatusMark`).
- **Low.** A box on a cycle keeps its refuted mark; VoiceOver hears what a box uses and is used by; the editor has
  previews and a smoke test; `ProblemManager.pinnedStatus` and unused helpers were removed; one list helper
  (`Prose.list`) replaces two; a test ties status words to labels; label numbers cannot overflow; a deleted statement
  is reported as gone; promotion targets compare equal across renders; the promote sheet was tidied.

### Checked in the running app

Launched with `-SangakuFixture YES`: the thread shows the pinned card and "Lemmas (7)" in the context row; the
window's minimum is 1136 × 652 with the inspector, which gets 340 pt. The inspector was checked in offscreen
renders (light and dark). The inspector inside the real window, the promote sheet, the editor and the Add Dependency
menu were not seen: the snapshot tool cannot capture the macOS 26 inspector column or sheets, and the sheets' forms
do not render offscreen.

### Deferred

- **Look at the inspector, the promote sheet and the editor in the running app** (see above).
- **Wording versus steps.** A statement's status comes from its source steps, but its wording is not checked against
  them, and an edit keeps the status. Closing this needs the promoted or reviewed wording stored: a schema change.
- **A fidelity review is not tied to the informal wording** it compared; the text lock covers it for now. Store the
  wording with the review in Milestone 8 (schema change).
- **A second referee sees statuses from the first.** Lemmas promoted between two referee passes carry words like
  "checked by a model" into the second referee's context. Decide whether referee requests leave the status words
  out.
- **The role prompts say adopted lemmas carry "the status the researchers have given them".** Reword, with a new
  prompt version.
- **Removing an edge does not ask,** although it can raise a status; the change shows at once.
- **The composer's estimate can lag a status change** from a verdict or review until the next edit; a send always
  rebuilds from the store.
- **Deleting the message or branch a lemma came from** empties its source steps, so it falls to proposed and loses
  its provenance. Milestone 7 should block that or keep the reference.

### Next

Milestone 5: review. Step reviews, revisions resetting review, open objections and dismissal, re-check flags,
comments, the provenance bar and the keyboard flow. Mark Checked in the inspector becomes live then.

## 2026-10-17: A vanishing window after Milestone 4

While scrolling or resizing the example (`-SangakuFixture YES`), the window stopped responding and then disappeared;
the app kept running with no window.

### What was found

- No crash, hang report or error in the system log. A sample of the windowless copy showed its main thread idle, so
  nothing was stuck. The log shows the window closed after a click; why it stopped responding first is not known.
- Two instrumented copies (`-NSApplicationCrashOnExceptions YES`, a watcher recording the window twice a second)
  were used for a while without the freeze coming back. Resizing to 800–1512 pt wide by script did not reproduce it
  either.
- Found on the way: a launch restores the last session's windows, and when that session ended with its window
  closed, the app came up with no window at all.

### Fixed

- `WindowGroup` uses `.defaultLaunchBehavior(.presented)`, so every launch shows a window. Checked with the new
  debug flag `-SangakuCloseWindowAt <seconds>`: a run that ends with its window closed, then a normal launch, which
  now opens a window.

### Open

- The freeze itself is not explained. If it happens again, note what was on screen (which panel, a sheet, a menu)
  and the time, and leave the app running: its state can then be sampled before it is quit.

## 2026-10-18: Milestone 5, Review

### What was built

- **One per-step rule** (`Model/Values`, all pure):
  - `StepFacts` hold a step's revisions, reviews and comments as values; `StepFacts+Store` reads them from the
    store inside view bodies, so Observation tracks every relationship read.
  - `StepStandings.derive` gives each step of an attempt its standing: a person's ✓ on the current revision, open
    and dismissed objections, withdrawn and stale reviews, reviews that count for nothing (not from a person), what
    the referee's verdict says about the current text (`ModelCheck`), and the re-check flag with its causes.
  - Status rules 3 and 4 (`StatusInputs.make`), the Review screen, the progress line and the rotors all read it.
  - `ReviewProgress` ("4 of 6 steps checked by a person", notes for open objections and re-check flags),
    `StepProvenance` (versions with author and what changed), `AttemptReviewState` (an attempt's rows, progress,
    rotor lists, each step's history), `ReviewError`, `ReviewKeys` and `ReviewNavigation` (the keys as pure
    functions), `ReviewSelection` and `ReviewAttemptChoice` (which attempt is shown).
- **Rule 4 tightened.** A referee verdict covers a step only if the step's current revision is no later than the
  referee's request; a verdict with no request time covers nothing. `ThreadManager` records the request time on each
  verdict, and writes an attempt's steps only once.
- **`ReviewManager`**: mark ✓, ✗ or ? on the revision the person saw (refused if the step changed since), withdraw
  one's own ✓, dismiss an objection with a reason (optionally marking the version ✓ in the same change), revise a step,
  comment on a revision. Every write is the person using the app's, validated before anything changes, and timed
  after everything recorded on the attempt.
- **The Review screen** (⌘3):
  - The theorem, an attempt picker, the progress line and notes, a margin legend, and "Showing the steps of Lem 3"
    when opened from the inspector.
  - Each step: the provenance bar with letters or initials, the text (secondary ink until a person's ✓ counts), what
    it establishes, chips with glyph and words (person, re-check, referee), the model's confidence, a provenance
    line, open objection cards with Dismiss…, closed objections with their reasons, a comment thread, and the
    history (versions with earlier text, reviews, dismissals, withdrawals, comments).
  - The current step has the actions (✓ Correct, ✗ Wrong, ? Unclear, Comment, Revise…, Withdraw My ✓), the key
    legend and a comment composer (⌘↩ posts, Esc returns to the list).
  - Keys J, K, 1, 2, 3 and C on the step list; the Review menu; VoiceOver announcements for every mark and refusal;
    rotors "Unchecked steps" and "Delicate steps".
  - The Revise and Dismiss sheets, each saying what saving changes.
  - An empty state with "Go to Thread".
- **Entry points.** The referee's "Review Step by Step", "Review This Step" in a step's context menu and VoiceOver
  actions, and "Review Steps" in the inspector.
- **Context.** A step a person revised reaches models as "revised by the researcher", or by the collaborator's name.
- **Schema.** `StepComment`, `Step.comments`, `Review.withdrawnAt`, `RefereeVerdict.requestedAt`; `Review.isDismissed`
  removed. The existing store opened without a reset.
- **Fixture.** A fixed review timeline on the morning after the fan-out: ✓ You on step 1, ✓ MK on step 2, You revise
  step 3 and check it, ✓ You on step 4, A revises step 5 and You's ? on it is open, two comments on step 5. Still 4 of 6.
- **Debug flag.** `-SangakuStartView review` opens new windows on Review.

### Decisions

Recorded in `docs/DECISIONS.md` (2026-10-18): the architecture, the schema, rule 4 tightened (partly reversing the
Milestone 3 entry), one attempt with a picker, the entry points, objections and their dismissal, withdrawal, repeated
marks, re-check flags, comments, person revisions, forward-only times, the context wording, the keyboard, the look,
the non-lazy step list, and the side panel left for Milestone 8.

**Spec drift to reconcile** (not edited): the domain model lacks `StepComment`, `Review.withdrawnAt` and
`RefereeVerdict.requestedAt`; rule 4 should say the verdict covers the steps "on the text it saw"; the inspector's
"mark checked" is now "Review Steps"; the Reviews section and invariant 11 should add that the person who raised a ✗
or ? may withdraw it (see the next entry).

### Tests

372 tests in 66 suites (Swift Testing), all passing. Milestone 5 added 74:
- **Standings (invariants 1, 2, 10, 11):** a ✓ counts only from a person on the current revision; any new revision
  resets it and keeps the old ✓; an open ✗ or ? blocks every ✓, including later ones; only a person's dismissal with
  a reason closes it; a revision closes it; withdrawal never does; objections outlive their reviewer; confidence
  changes nothing.
- **Rule 4:** every `ModelCheck` case, equal times, ties, a missing request time, a step with no revision; through
  the store, a stored verdict with no request time, and a tie with one, cover nothing; a verdict never makes a step
  checked by a person.
- **Re-check:** later checked steps flagged, earlier, unchecked and withdrawn-only steps not; an objected step keeps
  the cause; text-only and whitespace-only revisions flag nothing; a fresh ✓ clears the flag; equal times flag; a
  flagged step's statement keeps its status (Lem 6).
- **One rule for every reader (invariant 3):** 200 seeded random attempts; standing, status inputs, progress and the
  spec's rule agree on every step.
- **Progress (invariant 8):** "4 of 6", never complete with an objection or a missing check; the example reads 4 of 6
  with one open objection and step 6 "checked by C only".
- **`ReviewManager`:** the reviewer is always the person using the app; mark then revise; rule 4 after a person's
  revision and a new pass; provenance and forward-only times with a clock set before everything, a referee request
  still running included; dismissal and its refusals; resolve as one change; stale revisions refused; comments on
  earlier versions; withdrawal, of both ✓s on a re-checked step too; repeats, beside an objection too; re-check flags
  and their clearing; drafts; Review shows the revision's text; every refusal changes nothing; one context change and
  one save per action, a comment a save only; observation of every kind of change.
- **Invariant 1 end to end:** a whole fan-out and referee pass writes no review, comment or person revision.
- **Context:** "revised by the researcher" and a collaborator's name; Lem 5's line.
- **Keys and window:** every key, every modifier, typing, held keys, the text-view probe, navigation at the ends;
  which attempt is shown; opening Review from each entry point; a new problem starting over.
- **Words:** the chips, the provenance, objection, dismissal and history lines, the legend, what a revision resets,
  the announcements (a ✓ beside an open objection is never "counting"), and how people are named.
- **Styles and layout:** no two standings differ only by colour; an objection is never drawn as a refutation; rows
  in full ink only when a ✓ counts; the margin's segments; the re-check glyph is its own; every row (current one
  included) and the header fit the narrowest workspace; Review fits a minimum window; smoke renders of the page (light
  and dark), rows in every state, the sheets and the empty state.
- **Updated for rule 4:** the example's statuses, the fixture's invariant tests, the graph tests and the referee-rule
  tests.

### Review

Three reviews (trust invariants, correctness, conventions). None found a defect in the trust rules. One finding was
high: initials badges were white on the near-white dark-mode ink, so a person's own badge could not be read. As
decided after the review, every finding was fixed except one, with tests:
- **High.** One badge for letters and initials, its text in the background colour, readable in both modes.
- **Medium.**
  - Withdrawing on a step checked twice (a fresh ✓ after a re-check) left the older ✓ counting; it now withdraws
    both.
  - "Comment on Step" from another step's menu now puts the keyboard in that step's field once it is shown, and
    unsent comments are kept per step instead of being lost when the step changes.
  - A ✓ beside an open objection was announced as counting; it is announced as blocked. A held 1, 2 or 3 no longer
    repeats.
  - Moving between steps no longer derives the attempt list and the statuses again: the current step is kept apart
    from which attempt is chosen.
  - The step list shows whether it has the keyboard.
  - The chips, the lines, what a revision resets and the announcements moved out of the views into `ReviewWording`,
    with tests. Duplicates became one: a generic environment action, `Pasteboard.copy`, `Prose.count`, one time
    order (`TimeOrdered`), one way to find the person using the app. Dead code went, including a field that made
    every row observe its step's statements and a test-only second composition of rule 4.
- **Low.** The time floor counts a referee request still running; a checked row has an ink border; Review shows the
  current revision's text rather than the step's copy of it; the sheets report a step with no recorded text as such;
  VoiceOver hears provenance once and can make any step current; step text is selectable; previews for the rows, the
  header, the history and the sheets; helpers in their own files; one wording for a missing person.
- **Deferred:** a partial attempt whose steps are all checked reads "3 of 3"; "partial" shows only in the picker.
  The AI-use statement (Milestone 8) must say so.

### Checked in the running app

Launched with `-SangakuFixture YES -SangakuStartView review`: Review shows Model A's attempt (the theorem's source),
the progress line, chips and margin bars as in the offscreen renders, and the step list ringed as having the
keyboard. Not checked by hand yet: the keys with real
text fields and sheets, ⌘-shortcuts with the list focused, Tab with and without Full Keyboard Access, and the
VoiceOver rotors (see Deferred).

### Deferred

- **Check the keyboard by hand** in the running app: J, K, 1, 2, 3 and C typed into the comment field and the sheets
  (they must be text); ⌘-shortcuts with the list focused; Tab with Full Keyboard Access on and off; the VoiceOver
  rotors and where focus lands after moving; "Comment on Step" from another step's menu.
- **Partial attempts in the progress line** (see Review).
- **Offscreen renders cannot show a `ScrollView`,** so the Review page is checked from its parts; the running app
  showed the whole screen.
- **The thread's step rows show the step's copy of its text,** which equals the current revision while every write
  goes through `ReviewManager`; Milestone 9's import must keep it so.
- **Old verdicts in the existing store** carry no request time, so their statements now show sketched until the
  attempts are refereed again.

### Next

Milestone 6: Compare. `AlignmentService`, the aligned table, the differences filter and blind mode.

## 2026-10-18: Taking back a mark

A key pressed by mistake was hard to take back: a ✓ could be withdrawn, but a ✗ or ? closed only by a revision or a
dismissal with a reason, and there was no undo.

### What changed

- **Undo.** A mark made since sangaku opened is taken back outright while nothing has been recorded on its step after
  it: the Undo button beside the confirmation, or Edit > Undo (⌘Z), with Redo, which marks the same version again.
  `ReviewManager.undoMark` refuses anything else (`cannotUndo`), and the refusal is shown on the step.
- **Withdrawing one's own objection.** The person who raised a ✗ or ? can withdraw it with the Withdraw button on its
  card; it closes, stays in the history marked withdrawn, and the row says so. Others still dismiss with a reason.
  A withdrawal that cannot be traced to a person leaves the objection open.
- Both were chosen when the question came up after the milestone; `docs/DECISIONS.md` (2026-10-18, Withdrawal and
  Undo) has the rules.

### Tests

375 tests in 66 suites, all passing. New: withdrawing one's own objection, refusing someone else's, and an
untraceable withdrawal leaving it open; the spec's rule in the random-attempt oracle includes withdrawal; undo
removing a mark as if never given; undo refused for a mark from before the session and for one with something
recorded after it; Edit > Undo and Redo through an `UndoManager`, and a refusal reported rather than swallowed; the
withdrawal lines and announcements.

### Spec

The spec's Reviews section and invariant 11 say a ✗ or ? closes only by a new revision or a person's dismissal with
a reason. They should add the raiser's withdrawal. Not edited.

## 2026-10-19: Milestone 6, Compare

### What was built

- **A pure comparison core** (`Model/Values/Compare`):
  - `ComparisonState` derives the table on every read from three layers: a person's corrections (an append-only log
    of pair, separate, judge and clear) over the model's rows over the pairing by label. Every step of both attempts
    is in exactly one row; each row is equivalent, diverging, one-sided, not compared, or out of date.
  - `LabelPairing` (the k-th step with a label in one attempt pairs with the k-th in the other), `RowOrder`,
    `CompareSummary`, the differences filter (which hides only rows judged equivalent on the current text), and
    `KeyPhrase`.
  - Blind mode: `SideOrder` (which attempt is "Attempt 1", from the IDs alone), `CompareBlind`, `HoldsVerdict` and
    `BlindShield` (withholds model-written text that names a model while blind).
  - `ComparePairChoice`, `AlignerChoice`, `CompareLayoutMode` and `ThreadAgreement` (the thread's collapsed runs and
    divergence).
- **`AlignmentService`**: re-pair, separate, judge (on the revisions read) and clear, and the blind verdict, all in
  the name of the person using the app; refusals change nothing.
- **The alignment request.** `OutputFormat.alignment`, the aligner prompt (`aligner@1`), `AlignmentBasis` (what the
  model is shown, and how its step numbers map back), `AlignmentParser` and `AlignmentMapper` (whole or nothing,
  failing closed), the `.alignment` context purpose (both attempts ended, nothing else of the thread, "Attempt 1/2"
  only), and `ThreadManager.align`/`alignPlan`. The record belongs to the comparison; stop, quit, delete and orphan
  recovery handle it. The demo transport answers an alignment.
- **Questions about a row.** `ThreadManager.ask` with `SendPlanner.readyQuestion`: a repair request to the author of a
  step, or a row to the referee, which answers with its own prompt (`referee-reply@1`) as a new message kind,
  `refereeReply`, never a verdict. Both are linked to the attempts, so they are withheld wherever the attempts are.
- **The Compare screen** (⌘2): title, the two attempts (pickers, or "Attempt 1 and Attempt 2" while blind), the
  filter, blind mode, the summary chips, the alignment status with Align…, Stop and View Context; rows as four columns
  from 680 points or as cards below, each with its steps (key phrase marked and spelled out), verdict chip, who decided
  it, the note, and a menu (pair with, separate, mark equivalent or diverging, clear my judgement); drag a step onto a
  row of the other attempt to pair them; J and K between rows; rotors for diverging, unmatched and out-of-date rows;
  the resolve panel (the blind verdict, repair and row-to-referee requests shown before they are sent, Adopt and the
  counterexample search disabled with a caption); the Align and question sheets.
- **Blind chrome.** While blind in Compare, the toolbar's model chips and the proof-structure inspector are hidden.
- **The thread.** A fan-out's later attempt collapses runs of matching steps ("Steps 1–4 match A's"), a banner names
  the row where the attempts part ways and opens Compare, and the referee message has "Compare Attempts".
- **`MathText` marks**: a range underlined and tinted where it keeps every formula whole; unmarked text is unchanged.
- **Also:** one `appEnvironment` modifier replaces six hand-kept lists of injected managers; `SeededGenerator` is
  shared by the property tests.
- **Fixture.** C's alignment of A and B at 11:16 (after the revisions): rows 1–4 equivalent, row 5 diverging with its
  key phrases, step 6 only in A.

### Decisions

Recorded in `docs/DECISIONS.md` (2026-10-19). The existing store opened with the new schema without a reset.

**Spec drift to reconcile** (not edited): the domain model's `Alignment` row (corrections, blind verdict, requests,
summary), `RequestRecord.alignment`, and the message kind `refereeReply`; blind mode's "until the user records a
verdict" is "which attempt holds", per comparison.

### Tests

450 tests in 80 suites, all passing. Milestone 6 added 75, 13 of them with the review's fixes:
- **The core:** label pairing, sanitising the model's rows (unknown and reused steps, odd verdicts), corrections over
  two different model layers, clearing, staleness on both layers and on unrecorded revisions, unreadable layers, the
  filter, row order, and 200 random cases where every step is in exactly one row, a person's pair always appears and a
  separated pair never does.
- **Blind mode (invariant 9):** side order symmetric, stable and about even; the reveal rule; `BlindShield` on unsafe
  and safe texts; nothing Compare says while hidden names a model, a slot or a provider (labels, aligner names, picker
  labels, run status, a failed alignment's error, blockers); `CompareIdentity` holds no author while hidden, is built
  hidden until a verdict, readable or not, is stored, and withholds a model's label in favour of what a step
  establishes.
- **The store:** the example's comparison read either way round; a revision making a row out of date; deleting the
  comparison changes no status (invariant 1); unreadable JSON; cascades; an unknown blind verdict.
- **`AlignmentService`:** re-pairing, judging on the revisions read and refused on a revised step, refusals changing
  nothing, steps given either way round, the comparison created on first write, the blind verdict once with who and
  when, and observation.
- **The request:** the schema closed, the prompt tags, the parser whole or nothing, the mapper's rules; the context
  (only the two attempts, no letters), unfinished and stray attempts refused (invariant 4), the provider policy
  (invariant 15), and only a referee-role slot aligning.
- **The lifecycle:** a run stored on the comparison and nowhere else with corrections kept; no review, verdict or status
  changed (invariant 1); stopped, failed and unreadable answers storing nothing; refusals sending nothing; quitting,
  deleting the problem and orphans; the demo transport end to end.
- **Questions about a row:** a repair as an ordinary reply that changes no step, a referee's row answer that writes no
  verdict, both excluded from later independent attempts, and refusals.
- **Screen:** row styles distinct without colour and never a check or a refutation; the words; drag pairing and the
  drag type (never text); key phrases that would cut a formula, swap prose and math, or cut `\(` from its formula
  (invariant 16), and a canonically equivalent match; the thread's runs and banner, and flagged steps kept open;
  window state and the J/K keys; stacked rows and the resolve panel fitting 260 points; Compare at a minimum window;
  smoke renders of the table (light and dark), blind cards, the header and resolve panel shown and blind, both
  sheets, the fan-out with its banner and the empty state.
- **Added at review:** separating, or pairing elsewhere, withdraws a judgement; a model's "no counterpart" and an
  out-of-date reading's note and marks; a person's pairing, separating and judging changing no review, standing or
  status (invariant 1); a step with no revision refused; an unreadable stored verdict never written over; `align`
  refusing a prover, an author and one attempt twice, orienting a reversed pair, and refused while attempts stream.

### Checked in the running app

Launched with `-SangakuFixture YES -SangakuStartView compare`: the four-column table with the summary chips, the
diverging row highlighted, both key phrases underlined in place, "No matching step" for step 6, the alignment status,
the J/K legend and the resolve panel; after the review's fixes, again, with the built Info.plist declaring
`local.sangaku.step`. Blind mode, the sheets, drag and drop, J and K, the Compare menu and the rotors were not tried
by hand.

### Review

Three reviewers (trust invariants, correctness, conventions) found three high-severity issues, nine medium and a
set of low ones and test gaps; all were fixed.
- **High.**
  - Blind mode (invariant 9): row labels, rotor entries, a failed alignment's provider error and the Align sheet's
    blockers could name a model; the hide-or-show decision was made in five places. Now one value,
    `CompareIdentity`, built by one function, carries every name Compare shows, and everything a model or provider
    wrote passes `BlindShield`.
  - Key phrases (invariant 16): a phrase cutting a formula was spelled out as raw LaTeX, or with prose set as math.
    `KeyPhrase.locate` now accepts a phrase only where every formula stays whole, and measures the mark from the
    matched text.
  - Accessibility: no focus ring on the row list before a row is current; a step cell's label hid its text from
    VoiceOver.
- **Medium.** Flagged steps folded into the thread's matching runs; an out-of-date model reading's note and marks,
  and one-sided rows that ignored revisions; `align` trusting the caller's order and checking neither the pair nor
  the aligner; the aligner's left-out context not shown (invariant 5); notices neither announced nor placed by their
  control, and fewer VoiceOver actions than documented; a judgement on a step with no revision, an unreadable
  verdict that kept Compare blind, a judgement returning after separation; the row handler reading its render, the
  filter re-deriving the comparison, and a drag payload any text field accepted.
- **Low.** Logic moved out of the view; dead error cases and members removed; one estimate wording, one "current
  text of a step", one announcement helper, one caption size, one provider check; the think-time taken from the
  composer; `ShortTime`, `ListKeyInput`, `ListNavigation` and `AttemptOption` named for what they are; a Compare
  menu and a J/K legend; partial attempts marked; stale and doubled doc comments corrected; dark and sheet previews.

### Deferred

- The partial-attempt progress wording (from Milestone 5), to Milestone 8.
- Trying blind mode, the sheets, drag and drop, the keys, the Compare menu and the rotors by hand.

### Next

Milestone 7, Branches: fork, dead ends with reasons in context, cherry-pick, and adopting an attempt as the main line
(the referee's and Compare's Adopt).
