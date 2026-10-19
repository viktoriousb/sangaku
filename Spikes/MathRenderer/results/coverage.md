Parsed: SwiftMath 41/79, SwiftMath + fallbacks 47/79, KaTeX 79/79

| Kind | LaTeX | SwiftMath | SwiftMath + fallbacks | KaTeX |
|---|---|---|---|---|
| core | `n_p \in \{1, q\},\ n_p \equiv 1 \pmod{p}` | ✗ Invalid command \pmod | ✗ Invalid command \pmod | ✓ |
| core | `q \mid p + 1,\quad q \nmid p - 1` | ✗ Invalid command \nmid | ✗ Invalid command \nmid | ✓ |
| core | `\|G\| = p^2 q` | ✓ | ✓ | ✓ |
| core | `\frac{a}{b} + \tfrac{1}{2} + \dfrac{x}{y}` | ✗ Invalid command \tfrac | ✗ Invalid command \tfrac | ✓ |
| core | `\binom{n}{k}` | ✓ | ✓ | ✓ |
| core | `\sum_{k=0}^{n} \binom{n}{k} = 2^n` | ✓ | ✓ | ✓ |
| core | `\int_0^1 f(x)\,dx` | ✓ | ✓ | ✓ |
| core | `\lim_{n \to \infty} a_n` | ✓ | ✓ | ✓ |
| core | `\left( \frac{p}{q} \right)` | ✓ | ✓ | ✓ |
| core | `\sqrt[3]{x} + \sqrt{2}` | ✓ | ✓ | ✓ |
| core | `a \bmod n,\ a \equiv b \pmod{n}` | ✗ Invalid command \bmod | ✗ Invalid command \bmod | ✓ |
| fonts | `\mathbb{Z}/n\mathbb{Z}` | ✓ | ✓ | ✓ |
| fonts | `\mathfrak{g} \oplus \mathfrak{h}` | ✓ | ✓ | ✓ |
| fonts | `\mathcal{O}_X` | ✓ | ✓ | ✓ |
| fonts | `\mathscr{F}` | ✗ Invalid command \mathscr | ✗ Invalid command \mathscr | ✓ |
| fonts | `\mathrm{Gal}(L/K)` | ✓ | ✓ | ✓ |
| fonts | `\mathbf{v} + \boldsymbol{\alpha}` | ✗ Invalid command \boldsymbol | ✗ Invalid command \boldsymbol | ✓ |
| fonts | `\mathsf{Set}` | ✓ | ✓ | ✓ |
| fonts | `x = 1 \text{ if } x > 0` | ✓ | ✓ | ✓ |
| operators | `\operatorname{Syl}_r(G)` | ✗ Invalid command \operatorname | ✓ | ✓ |
| operators | `\operatorname{Hom}_R(M, N)` | ✗ Invalid command \operatorname | ✓ | ✓ |
| operators | `\ker \varphi \cap \operatorname{im} \psi` | ✗ Invalid command \operatorname | ✓ | ✓ |
| operators | `\deg f \le \dim V` | ✓ | ✓ | ✓ |
| operators | `\varprojlim_n \mathbb{Z}/p^n` | ✗ Invalid command \varprojlim | ✗ Invalid command \varprojlim | ✓ |
| operators | `\varinjlim_i M_i` | ✗ Invalid command \varinjlim | ✗ Invalid command \varinjlim | ✓ |
| operators | `\operatorname*{colim}_{i \in I} F(i)` | ✗ Invalid command \operatorname | ✓ | ✓ |
| arrows | `f \colon A \to B` | ✓ | ✓ | ✓ |
| arrows | `x \mapsto x^2` | ✓ | ✓ | ✓ |
| arrows | `A \hookrightarrow B \twoheadrightarrow C` | ✗ Invalid command \hookrightarrow | ✗ Invalid command \hookrightarrow | ✓ |
| arrows | `A \xrightarrow{\ f\ } B` | ✗ Invalid command \xrightarrow | ✗ Invalid command \xrightarrow | ✓ |
| arrows | `A \overset{\sim}{\to} B` | ✗ Invalid command \overset | ✗ Invalid command \overset | ✓ |
| arrows | `P \Rightarrow Q \iff R` | ✓ | ✓ | ✓ |
| arrows | `A \longrightarrow B` | ✓ | ✓ | ✓ |
| relations | `A \cong B \simeq C \sim D \approx E` | ✓ | ✓ | ✓ |
| relations | `a \not\equiv b,\ a \neq b` | ✗ Invalid command \not | ✗ Invalid command \not | ✓ |
| relations | `x \leq y \geqslant z` | ✗ Invalid command \geqslant | ✗ Invalid command \geqslant | ✓ |
| relations | `A \subseteq B \nsubseteq C \subsetneq D` | ✗ Invalid command \nsubseteq | ✗ Invalid command \nsubseteq | ✓ |
| relations | `N \trianglelefteq G,\ N \lhd G,\ N \unlhd G` | ✗ Invalid command \trianglelefteq | ✗ Invalid command \trianglelefteq | ✓ |
| delimiters | `\langle x, y \mid x^2 = y^3 = 1 \rangle` | ✓ | ✓ | ✓ |
| delimiters | `\lvert G \rvert,\ \lVert v \rVert` | ✗ Invalid command \lvert | ✗ Invalid command \lvert | ✓ |
| delimiters | `\lfloor x \rfloor + \lceil y \rceil` | ✓ | ✓ | ✓ |
| delimiters | `\left\lvert \frac{a}{b} \right\rvert \le \tfrac12` | ✗ Invalid delimiter for left: lvert | ✗ Invalid delimiter for left: lvert | ✓ |
| bigops | `\bigoplus_{i \in I} M_i` | ✓ | ✓ | ✓ |
| bigops | `\bigotimes_{k} V_k` | ✓ | ✓ | ✓ |
| bigops | `\bigcup_{n} A_n \cap \bigcap_n B_n` | ✓ | ✓ | ✓ |
| bigops | `\coprod_{i} X_i` | ✓ | ✓ | ✓ |
| bigops | `\prod_{p} (1 - p^{-s})^{-1}` | ✓ | ✓ | ✓ |
| accents | `\widehat{G},\ \widetilde{X},\ \overline{\mathbb{Q}}` | ✓ | ✓ | ✓ |
| accents | `\bar{x},\ \hat{x},\ \vec{v},\ \dot{x}` | ✓ | ✓ | ✓ |
| accents | `\underbrace{a + \cdots + a}_{n}` | ✗ Invalid command \underbrace | ✗ Invalid command \underbrace | ✓ |
| accents | `\overbrace{1 + \cdots + 1}^{m}` | ✗ Invalid command \overbrace | ✗ Invalid command \overbrace | ✓ |
| symbols | `\forall x\, \exists y\, \neg P` | ✓ | ✓ | ✓ |
| symbols | `\Gamma \vdash \varphi,\ M \models T` | ✗ Invalid command \vdash | ✗ Invalid command \vdash | ✓ |
| symbols | `\top, \bot, \varnothing, \emptyset` | ✗ Invalid command \varnothing | ✗ Invalid command \varnothing | ✓ |
| symbols | `\ell, \partial, \nabla, \infty, \aleph_0` | ✓ | ✓ | ✓ |
| symbols | `\dots, \cdots, \ldots, \vdots, \ddots` | ✗ Invalid command \dots | ✗ Invalid command \dots | ✓ |
| environments | `f(x) = \begin{cases} 1 & x > 0 \\ 0 & \text{otherwise} \end{cases}` | ✓ | ✓ | ✓ |
| environments | `\begin{aligned} (p-1)(p+1) &= p^2 - 1 \\ &\equiv 0 \pmod{q} \end{aligned}` | ✗ Invalid command \pmod | ✗ Invalid command \pmod | ✓ |
| environments | `\begin{pmatrix} a & b \\ c & d \end{pmatrix}` | ✓ | ✓ | ✓ |
| environments | `\begin{bmatrix} 1 & 0 \\ 0 & 1 \end{bmatrix}` | ✓ | ✓ | ✓ |
| environments | `\begin{pmatrix} a_{11} & \cdots & a_{1n} \\ \vdots & \ddots & \vdots \\ a_{m1} & \cdots & a_{mn} \end{pmatrix}` | ✓ | ✓ | ✓ |
| environments | `\begin{array}{c\|c} a & b \\ \hline c & d \end{array}` | ✗ Invalid command \hline | ✗ Invalid command \hline | ✓ |
| environments | `\begin{CD} A @>f>> B \\ @VgVV @VVhV \\ C @>>k> D \end{CD}` | ✗ Unknown environment CD | ✗ Unknown environment CD | ✓ |
| environments | `\begin{gathered} x = 1 \\ y = 2 \end{gathered}` | ✗ Unknown environment gathered | ✗ Unknown environment gathered | ✓ |
| environments | `\left(\begin{smallmatrix} a & b \\ c & d \end{smallmatrix}\right)` | ✗ Unknown environment smallmatrix | ✗ Unknown environment smallmatrix | ✓ |
| misc | `a \stackrel{?}{=} b` | ✗ Invalid command \stackrel | ✗ Invalid command \stackrel | ✓ |
| misc | `\boxed{x = 1}` | ✗ Invalid command \boxed | ✗ Invalid command \boxed | ✓ |
| misc | `\sum_{\substack{i < j \\ i, j \in I}} a_{ij}` | ✗ Invalid command \substack | ✗ Invalid command \substack | ✓ |
| misc | `x \phantom{y} z \quad a \qquad b \, c \; d \! e` | ✗ Invalid command \phantom | ✗ Invalid command \phantom | ✓ |
| misc | `{}^{t}A` | ✓ | ✓ | ✓ |
| misc | `\color{red}{x} + y` | ✓ | ✓ | ✓ |
| macros | `\Z/p\Z` | ✓ | ✓ | ✓ |
| macros | `\abs{G} = 12` | ✗ Invalid command \lvert | ✗ Invalid command \lvert | ✓ |
| macros | `\Syl{p}{G}` | ✗ Invalid command \operatorname | ✓ | ✓ |
| macros | `\Hom(M, N) \cong \Aut(G)` | ✗ Invalid command \operatorname | ✓ | ✓ |
| macros | `\set{x \mid x > 0}` | ✓ | ✓ | ✓ |
| unicode | `p ≠ q` | ✓ | ✓ | ✓ |
| unicode | `x ∈ G, q ∣ p + 1` | ✓ | ✓ | ✓ |
| unicode | `n₃ = 4` | ✓ | ✓ | ✓ |
