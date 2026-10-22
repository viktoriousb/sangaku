# sangaku

A native macOS workspace for mathematical proofs: an IDE for mathematics.

A code IDE treats a program as structured parts it can check and navigate. sangaku does the same for a proof. A
problem has a pinned statement, a notation registry, statements that depend on each other, and proof steps with an
author history. Each statement carries a status derived from the evidence behind it. The app shows what every claim
rests on, what has been checked and by whom, and what is still provisional, so that plausible-but-wrong mathematics
is hard to miss.

Language models and collaborators can take part: drafting attempts, refereeing them, reviewing steps. They are
optional tools inside the workspace, not its centre.

> **Status: early development.** Eight of nine planned milestones are done.
> The data format can still change without a migration, so do not keep research you care about in it yet. Today a
> proof's steps come from a model's attempt; writing and importing your own proofs arrives with a later milestone (see
> the roadmap).

## The workspace

- **Problems and notation.** Pin the statement you are working on. Keep a notation registry of symbols, meanings and
  LaTeX macros, imported from a preamble if you have one. The macros apply everywhere the problem's mathematics is
  shown.
- **Statements and dependencies.** The theorem, and the lemmas and claims promoted from runs of proof steps, form a
  graph of what uses what, shown in the proof-structure inspector. A dependency that would close a cycle is refused.
- **Derived status.** Every statement shows a status computed from its evidence on every read, and never more than
  the weakest thing it uses (see below).
- **Step-by-step review.** Read a proof in reading mode and mark each step ✓, ✗ or ?, on the exact version you read.
  Comment, revise steps, and close objections with a reason or withdraw your own. Undo takes back a mark made by
  mistake. The keyboard covers the whole flow: J and K to move, 1, 2 and 3 to mark, C to comment.
- **Provenance.** Every version of a step records who wrote it, and the margin shows it. A changed step loses its
  checks; later steps that relied on what it established are flagged for a second look.
- **Compare.** Line two attempts up step by step, paired by what each step establishes rather than by position, and
  see where they part ways. Re-pair, separate or judge rows yourself; your corrections are kept. Blind mode hides which
  model wrote which attempt until you record which one holds.
- **Branches.** Approaches form a tree. Fork from any message, mark a branch as a dead end with the reason it died,
  park it, or reopen it; choose whether a dead end's reason is told to models. Adopt an attempt as the main line's
  proof, and salvage a step from a dead branch as a lemma.
- **Mathematics set exactly.** Formulas are typeset as text where they are simple and by an embedded TeX engine
  where they are not. A formula neither can set is shown as its LaTeX source with a warning, never approximated.

### How status works

A statement's status is the first of these that holds:

1. **Refuted:** a person accepted a refutation.
2. **Verified in Lean:** Lean accepts its code with no errors and no `sorry`, the app's own kernel check finds only
   the standard axioms (`propext`, `Classical.choice`, `Quot.sound`), and a person confirmed that the Lean statement
   says what the informal one does.
3. **Checked by a person:** every source step has a person's ✓ on its current version and no open ✗ or ?.
4. **Checked by a model:** a referee found the attempt complete, on the text it was actually shown.
5. **Sketched:** it has source steps.
6. **Proposed:** otherwise.

It is then capped by everything it uses: no statement shows more than its weakest dependency, and a refuted
dependency is always visible. Unchecked mathematics is drawn provisionally everywhere, and status is never conveyed by
colour alone.

## Verification

Each check runs only when you click Check or Run on exactly what will run, offline, in a macOS sandbox that can write
only to a folder of its own and read only the tool's installation and, for Lean, Mathlib. The rest of your home folder
stays out of reach.

- **Lean 4 with Mathlib.** Choose a folder for a shared Lean workspace in Settings and fetch Mathlib into it once;
  that is the only step that uses the network. A problem's statements are checked together in one module. Lean
  compiles it, then a separate check by the app replays the compiled module through Lean's kernel and reads each
  statement's axioms, so nothing the code prints can stand in for the result. Code that programs Lean itself
  (meta-programs, new syntax, quoted names) is refused before anything runs.
- **Faithfulness.** A statement counts as verified in Lean only once a person confirms that its Lean statement says
  exactly what the informal statement says, on the two texts shown side by side. You can take a confirmation back.
- **Computations.** GAP, Sage or Python code tests a claim over an exact scope ("every group of order p²q ≤ 100").
  Each run is kept as evidence with its code, output and scope, never as a status. A counterexample the code reports
  refutes the statement only when a person accepts it, in their own words.
- **Citations.** Steps carry citations, which start unchecked. On a click, each is looked up in arXiv and zbMATH Open,
  sending only the words shown beforehand. A lookup that cannot decide leaves a citation unchecked, never "not found",
  and only a found citation is shown as a link.

## Optional: language models

- Ask a model about the problem, or ask several independently and have another referee their attempts once all have
  finished. Independent attempts never see each other.
- A model can align two attempts for Compare, draft Lean code for a statement (a formalizer), or write a computation
  that tests a claim (a scout). Its code waits in the thread, shown in full, until you check or run it.
- Every request shows exactly what was sent, what was left out to fit, and what it cost. Nothing about a problem is
  sent until you allow a provider for that problem.
- A model's output can never make a step "checked by a person" or a statement "verified", cannot close an
  objection, and cannot refute a statement.
- The first provider is Anthropic. The API key is entered in Settings (⌘,) and stored in the macOS Keychain only.

## Optional: collaborators

- Reviews, comments and revisions record the person who made them, so a collaborator's checks and objections can sit
  beside yours, each with its history.
- Sharing a problem as a folder of plain files, and merging a collaborator's copy into yours, arrive with a later
  milestone. Until then, everything on this Mac is reviewed in your name.

## Requirements

- macOS 26 or later.
- Xcode 27.1 to build (the version it is developed with; earlier versions are untested).
- An Anthropic API key only if you want to use models.
- For Lean checks: [elan](https://github.com/leanprover/elan). Fetching Mathlib installs the pinned Lean release and
  downloads Mathlib's compiled files, several gigabytes, into the workspace folder you choose.
- For computations: Python 3, GAP or Sage, found in `/opt/homebrew/bin` or `/usr/local/bin`, or chosen in Settings.

## Building

1. Clone the repository and open `sangaku.xcodeproj`.
2. Optional: copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your Team ID. Without one the
   app is signed to run locally, and the Keychain asks again for the API key after every rebuild.
3. Build and run the `sangaku` scheme.

Run the tests with:

```sh
xcodebuild test -project sangaku.xcodeproj -scheme sangaku -destination 'platform=macOS'
```

### Trying it with the example

Debug builds accept `-SangakuFixture YES` as a launch argument. The app then opens a worked example in memory (a
group of order p²q has a normal Sylow subgroup, with two attempts, a referee, a partly reviewed proof and branches) and
never touches your own data. `-SangakuFixtureVerified YES` opens it with Lean results, a Lean draft, computations and
citations to look up. Add `-SangakuStartView review` to open it on Review.

## Where your data lives

- Problems, statements, steps, reviews and verification results: a local SwiftData store in
  `~/Library/Application Support/sangaku/`.
- Each check or computation runs in a folder of its own under `Work/` there, removed when the run ends.
- The Lean workspace, with Mathlib: the folder you choose in Settings.
- The API key, if you use models: the macOS Keychain.
- Nothing is synced. Requests go only to the providers a problem allows, and every request records the exact text
  that was sent. Fetching Mathlib and looking citations up reach the network only when you click.

## Project layout

```
sangaku/          the app: App, Model, Managers, Services, Views, Resources
sangakuTests/     unit, layout and render tests (Swift Testing)
Vendor/MicroTeX/  the vendored TeX typesetting engine, with our patches
Design/           the screen mockups the views follow
Spikes/           a throwaway math-renderer comparison, kept for its results
docs/             DECISIONS.md (what was decided and why) and PROGRESS.md (milestone records)
```

## Roadmap

Done:
1. The workspace shell and exact math rendering.
2. Asking one model.
3. Asking several models, with a referee.
4. Statements, dependencies and derived status.
5. Step-by-step review.
6. Compare: aligning two attempts step by step, with blind mode.
7. Branches: approaches as a tree, with dead ends and the reasons they died.
8. Verification and export: Lean checks, computations and citation checks, sandboxed; LaTeX, a hashtag manuscript, a
   Lean project, and an AI-use statement generated from provenance that never claims more checking than was done.

Next:

9. **Plain files and collaboration:** a plain-file copy of each problem, merging a collaborator's copy, and importing
   your own LaTeX drafts as proofs.

## Third-party components

- [MicroTeX](https://github.com/NanoMichael/MicroTeX) (MIT), vendored in `Vendor/MicroTeX` with the changes listed in
  `Vendor/MicroTeX/PATCHES.md`.
- The hashtag kit (MIT), bundled as `sangaku/Resources/Export/HashtagKit.json`, pinned from a commit of the kit by
  `scripts/pin-hashtag-kit.py`.
- XITS Math (SIL Open Font License 1.1), converted for MicroTeX, in `sangaku/Resources/Fonts` with its licence.
- STIX Two Text and STIX Two Math are used from the copies macOS ships; they are not included.
- Lean, Mathlib, Python, GAP and Sage are not included; the app runs the copies you install or fetch.

## Licence

MIT. See [LICENSE](LICENSE). Third-party components keep their own licences.
