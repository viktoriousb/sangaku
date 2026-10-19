// What mathematicians actually type, grouped by kind. The prose rows are the mockup's proof steps.

enum Corpus {
    /// A user preamble, as the notation registry would hold it.
    static let preamble = #"""
    \newcommand{\Z}{\mathbb{Z}}
    \newcommand{\Q}{\mathbb{Q}}
    \newcommand{\abs}[1]{\lvert #1 \rvert}
    \newcommand{\set}[1]{\{#1\}}
    \newcommand{\Syl}[2]{\operatorname{Syl}_{#1}(#2)}
    \DeclareMathOperator{\Hom}{Hom}
    \DeclareMathOperator{\Aut}{Aut}
    """#

    struct Item {
        let category: String
        let tex: String
        var display = false
    }

    static let expressions: [Item] = [
        // Core
        Item(category: "core", tex: #"n_p \in \{1, q\},\ n_p \equiv 1 \pmod{p}"#),
        Item(category: "core", tex: #"q \mid p + 1,\quad q \nmid p - 1"#),
        Item(category: "core", tex: #"|G| = p^2 q"#),
        Item(category: "core", tex: #"\frac{a}{b} + \tfrac{1}{2} + \dfrac{x}{y}"#),
        Item(category: "core", tex: #"\binom{n}{k}"#),
        Item(category: "core", tex: #"\sum_{k=0}^{n} \binom{n}{k} = 2^n"#, display: true),
        Item(category: "core", tex: #"\int_0^1 f(x)\,dx"#, display: true),
        Item(category: "core", tex: #"\lim_{n \to \infty} a_n"#),
        Item(category: "core", tex: #"\left( \frac{p}{q} \right)"#),
        Item(category: "core", tex: #"\sqrt[3]{x} + \sqrt{2}"#),
        Item(category: "core", tex: #"a \bmod n,\ a \equiv b \pmod{n}"#),
        // Fonts
        Item(category: "fonts", tex: #"\mathbb{Z}/n\mathbb{Z}"#),
        Item(category: "fonts", tex: #"\mathfrak{g} \oplus \mathfrak{h}"#),
        Item(category: "fonts", tex: #"\mathcal{O}_X"#),
        Item(category: "fonts", tex: #"\mathscr{F}"#),
        Item(category: "fonts", tex: #"\mathrm{Gal}(L/K)"#),
        Item(category: "fonts", tex: #"\mathbf{v} + \boldsymbol{\alpha}"#),
        Item(category: "fonts", tex: #"\mathsf{Set}"#),
        Item(category: "fonts", tex: #"x = 1 \text{ if } x > 0"#),
        // Operators
        Item(category: "operators", tex: #"\operatorname{Syl}_r(G)"#),
        Item(category: "operators", tex: #"\operatorname{Hom}_R(M, N)"#),
        Item(category: "operators", tex: #"\ker \varphi \cap \operatorname{im} \psi"#),
        Item(category: "operators", tex: #"\deg f \le \dim V"#),
        Item(category: "operators", tex: #"\varprojlim_n \mathbb{Z}/p^n"#),
        Item(category: "operators", tex: #"\varinjlim_i M_i"#),
        Item(category: "operators", tex: #"\operatorname*{colim}_{i \in I} F(i)"#, display: true),
        // Arrows
        Item(category: "arrows", tex: #"f \colon A \to B"#),
        Item(category: "arrows", tex: #"x \mapsto x^2"#),
        Item(category: "arrows", tex: #"A \hookrightarrow B \twoheadrightarrow C"#),
        Item(category: "arrows", tex: #"A \xrightarrow{\ f\ } B"#),
        Item(category: "arrows", tex: #"A \overset{\sim}{\to} B"#),
        Item(category: "arrows", tex: #"P \Rightarrow Q \iff R"#),
        Item(category: "arrows", tex: #"A \longrightarrow B"#),
        // Relations
        Item(category: "relations", tex: #"A \cong B \simeq C \sim D \approx E"#),
        Item(category: "relations", tex: #"a \not\equiv b,\ a \neq b"#),
        Item(category: "relations", tex: #"x \leq y \geqslant z"#),
        Item(category: "relations", tex: #"A \subseteq B \nsubseteq C \subsetneq D"#),
        Item(category: "relations", tex: #"N \trianglelefteq G,\ N \lhd G,\ N \unlhd G"#),
        // Delimiters
        Item(category: "delimiters", tex: #"\langle x, y \mid x^2 = y^3 = 1 \rangle"#),
        Item(category: "delimiters", tex: #"\lvert G \rvert,\ \lVert v \rVert"#),
        Item(category: "delimiters", tex: #"\lfloor x \rfloor + \lceil y \rceil"#),
        Item(category: "delimiters", tex: #"\left\lvert \frac{a}{b} \right\rvert \le \tfrac12"#),
        // Big operators
        Item(category: "bigops", tex: #"\bigoplus_{i \in I} M_i"#, display: true),
        Item(category: "bigops", tex: #"\bigotimes_{k} V_k"#),
        Item(category: "bigops", tex: #"\bigcup_{n} A_n \cap \bigcap_n B_n"#),
        Item(category: "bigops", tex: #"\coprod_{i} X_i"#),
        Item(category: "bigops", tex: #"\prod_{p} (1 - p^{-s})^{-1}"#, display: true),
        // Accents
        Item(category: "accents", tex: #"\widehat{G},\ \widetilde{X},\ \overline{\mathbb{Q}}"#),
        Item(category: "accents", tex: #"\bar{x},\ \hat{x},\ \vec{v},\ \dot{x}"#),
        Item(category: "accents", tex: #"\underbrace{a + \cdots + a}_{n}"#, display: true),
        Item(category: "accents", tex: #"\overbrace{1 + \cdots + 1}^{m}"#, display: true),
        // Logic and symbols
        Item(category: "symbols", tex: #"\forall x\, \exists y\, \neg P"#),
        Item(category: "symbols", tex: #"\Gamma \vdash \varphi,\ M \models T"#),
        Item(category: "symbols", tex: #"\top, \bot, \varnothing, \emptyset"#),
        Item(category: "symbols", tex: #"\ell, \partial, \nabla, \infty, \aleph_0"#),
        Item(category: "symbols", tex: #"\dots, \cdots, \ldots, \vdots, \ddots"#),
        // Environments
        Item(category: "environments", tex: #"f(x) = \begin{cases} 1 & x > 0 \\ 0 & \text{otherwise} \end{cases}"#, display: true),
        Item(category: "environments", tex: #"\begin{aligned} (p-1)(p+1) &= p^2 - 1 \\ &\equiv 0 \pmod{q} \end{aligned}"#, display: true),
        Item(category: "environments", tex: #"\begin{pmatrix} a & b \\ c & d \end{pmatrix}"#, display: true),
        Item(category: "environments", tex: #"\begin{bmatrix} 1 & 0 \\ 0 & 1 \end{bmatrix}"#, display: true),
        Item(category: "environments", tex: #"\begin{pmatrix} a_{11} & \cdots & a_{1n} \\ \vdots & \ddots & \vdots \\ a_{m1} & \cdots & a_{mn} \end{pmatrix}"#, display: true),
        Item(category: "environments", tex: #"\begin{array}{c|c} a & b \\ \hline c & d \end{array}"#, display: true),
        Item(category: "environments", tex: #"\begin{CD} A @>f>> B \\ @VgVV @VVhV \\ C @>>k> D \end{CD}"#, display: true),
        Item(category: "environments", tex: #"\begin{gathered} x = 1 \\ y = 2 \end{gathered}"#, display: true),
        Item(category: "environments", tex: #"\left(\begin{smallmatrix} a & b \\ c & d \end{smallmatrix}\right)"#),
        // Miscellaneous
        Item(category: "misc", tex: #"a \stackrel{?}{=} b"#),
        Item(category: "misc", tex: #"\boxed{x = 1}"#),
        Item(category: "misc", tex: #"\sum_{\substack{i < j \\ i, j \in I}} a_{ij}"#, display: true),
        Item(category: "misc", tex: #"x \phantom{y} z \quad a \qquad b \, c \; d \! e"#),
        Item(category: "misc", tex: #"{}^{t}A"#),
        Item(category: "misc", tex: #"\color{red}{x} + y"#),
        // User macros from the preamble
        Item(category: "macros", tex: #"\Z/p\Z"#),
        Item(category: "macros", tex: #"\abs{G} = 12"#),
        Item(category: "macros", tex: #"\Syl{p}{G}"#),
        Item(category: "macros", tex: #"\Hom(M, N) \cong \Aut(G)"#),
        Item(category: "macros", tex: #"\set{x \mid x > 0}"#),
        // Unicode that models often emit
        Item(category: "unicode", tex: "p ≠ q"),
        Item(category: "unicode", tex: "x ∈ G, q ∣ p + 1"),
        Item(category: "unicode", tex: "n₃ = 4"),
    ]

    /// Proof steps from the mockup, with inline math as `$…$`.
    static let prose: [String] = [
        #"$n_p \in \{1, q\}$, $n_p \equiv 1 \pmod{p}$; $n_q \in \{1, p, p^2\}$, $n_q \equiv 1 \pmod{q}$."#,
        #"If neither Sylow subgroup is normal, then $n_p = q$, so $q \equiv 1 \pmod{p}$ and in particular $q > p$."#,
        #"$n_q = p$ would need $p \equiv 1 \pmod{q}$, impossible since $1 < p < q$. Hence $n_q = p^2$."#,
        #"So $q \mid p^2 - 1 = (p - 1)(p + 1)$. As $0 < p - 1 < q$, $q \nmid p - 1$, hence $q \mid p + 1$."#,
        #"Since $q \mid p + 1$ and $q > p$, we get $q = p + 1$. Of two consecutive integers greater than $2$ one is even, so the primes $p, q$ must be $2, 3$, and $\abs{G} = 12$."#,
        #"If $\abs{G} = 12$ and $n_3 = 4$, the four Sylow $3$-subgroups meet pairwise trivially and contribute $8$ elements of order $3$. The remaining $4$ elements form the unique Sylow $2$-subgroup, which is therefore normal."#,
        #"Thus $\Hom_{\Z}(\Z/n\Z, \Q/\Z) \cong \Z/n\Z$, and $\varprojlim_n \Z/p^n\Z \xrightarrow{\sim} \Z_p$ is an isomorphism of topological rings, with $\overline{\mathbb{Q}} \supseteq \mathbb{Q}$."#,
        #"The sum $\sum_{k=0}^{n} \binom{n}{k} x^k = (1 + x)^n$ and the fraction $\frac{p^2 - 1}{q}$ sit inline, as does $\left\lvert \frac{a}{b} \right\rvert \le \tfrac12$."#,
    ]

    /// `count` rows cycling through the prose samples, numbered like proof steps.
    static func rows(_ count: Int) -> [String] {
        (0..<count).map { "\($0 + 1). " + prose[$0 % prose.count] }
    }

    enum Segment: Equatable {
        case text(String)
        case math(String)
    }

    /// Splits prose at unescaped `$` signs.
    static func segments(_ s: String) -> [Segment] {
        var out: [Segment] = []
        var buffer = ""
        var inMath = false
        var previous: Character = " "
        for ch in s {
            if ch == "$" && previous != "\\" {
                if !buffer.isEmpty { out.append(inMath ? .math(buffer) : .text(buffer)) }
                buffer = ""
                inMath.toggle()
            } else {
                buffer.append(ch)
            }
            previous = ch
        }
        if !buffer.isEmpty { out.append(inMath ? .math(buffer) : .text(buffer)) }
        return out
    }
}
