#if DEBUG
import Foundation

/// The fixture's Lean code: what the example's lemmas look like in the problem's module. Written to read like real
/// Mathlib code; the fixture records its checks without running Lean.
enum LeanFixtureCode {
    static let environment = LeanEnvironment(toolchain: LeanPin.toolchain, leanVersion: "4.35.0",
                                             mathlibRev: LeanPin.mathlibRev)

    static let lemma1 = LeanSource(
        statementPart: """
        theorem main {G : Type*} [Group G] [Finite G] {p q : ℕ} [Fact p.Prime] [Fact q.Prime]
            (hG : Nat.card G = p ^ 2 * q) :
            (Nat.card (Sylow p G) = 1 ∨ Nat.card (Sylow p G) = q) ∧ Nat.card (Sylow p G) ≡ 1 [MOD p]
        """,
        proofPart: """
        := by
          refine ⟨?_, card_sylow_modEq_one p G⟩
          exact card_sylow_eq_one_or_eq hG
        """)

    static let lemma2 = LeanSource(
        statementPart: """
        theorem main {G : Type*} [Group G] [Finite G] {p q : ℕ} [Fact p.Prime] [Fact q.Prime]
            (hG : Nat.card G = p ^ 2 * q)
            (h : ∀ r : ℕ, ∀ P : Sylow r G, ¬ (P : Subgroup G).Normal) :
            p < q
        """,
        proofPart: """
        := by
          have hp := Sylow.card_eq_q_of_not_normal hG (h p)
          exact lt_of_card_sylow_eq hp
        """)

    static let lemma3 = LeanSource(
        statementPart: """
        theorem main {p q : ℕ} (hp : p.Prime) (hq : q.Prime) (hlt : p < q) (hdvd : q ∣ p + 1) :
            p = 2 ∧ q = 3
        """,
        proofPart: """
        := by
          have h := Nat.le_of_dvd (Nat.succ_pos p) hdvd
          obtain rfl : q = p + 1 := by omega
          exact Nat.Prime.eq_two_three_of_succ hp hq
        """)

    static let lemma4 = LeanSource(
        statementPart: """
        theorem main {G : Type*} [Group G] [Finite G] (hG : Nat.card G = 12)
            (h3 : Nat.card (Sylow 3 G) = 4) :
            ∀ P : Sylow 2 G, (P : Subgroup G).Normal
        """,
        proofPart: """
        := by
          intro P
          -- 8 elements of order 3 leave room for one Sylow 2-subgroup only
          sorry
        """)

    static let lemma6 = LeanSource(
        statementPart: """
        theorem main {G : Type*} [Group G] [Finite G] {p q : ℕ} [Fact p.Prime] [Fact q.Prime]
            (hG : Nat.card G = p ^ 2 * q) (hq : Nat.card (Sylow q G) = p) :
            q ∣ p - 1
        """,
        proofPart: """
        := by
          have h := card_sylow_modEq_one q G
          rw [hq] at h
          exact (Nat.modEq_iff_dvd' (Fact.out : p.Prime).one_le).mp h.symm
        """)

    static let lemma7 = LeanSource(
        statementPart: """
        theorem main {p q : ℕ} (hq : q ∣ p - 1) (hlt : p < q) (hp : 2 ≤ p) : False
        """,
        proofPart: """
        := by
          have := Nat.le_of_dvd (by omega) hq
          exact Sylow.card_eq_p this hlt
        """)

    static let lemma5 = LeanSource(
        statementPart: """
        theorem main {G : Type*} [Group G] [Finite G] {p q : ℕ} [Fact p.Prime] [Fact q.Prime]
            (hG : Nat.card G = p ^ 2 * q)
            (hp : Nat.card (Sylow p G) = q) (hq : Nat.card (Sylow q G) = p ^ 2) :
            False
        """,
        proofPart: """
        := by
          exact Sylow.false_of_counts hG hp hq
        """)
}
#endif
