#!/usr/bin/env python3
"""Telegram-style one-color doodle wallpapers (transparent SVG)."""
from __future__ import annotations

import html
import math
import random
import subprocess
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "preview" / "wallpapers"
W, H = 720, 1480
S = "currentColor"


def g(inner: str, vb: int = 48) -> str:
    return f'<g transform="translate({-vb/2},{-vb/2})">{inner}</g>'


def ps(*ds: str, sw: float = 1.55) -> str:
    bits = []
    for d in ds:
        bits.append(
            f'<path d="{d}" fill="none" stroke="{S}" stroke-width="{sw}" '
            f'stroke-linecap="round" stroke-linejoin="round"/>'
        )
    return "".join(bits)


def c(cx, cy, r, sw=1.55, fill=False) -> str:
    if fill:
        return f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{S}" stroke="none"/>'
    return (
        f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="{S}" '
        f'stroke-width="{sw}"/>'
    )


def ell(cx, cy, rx, ry, sw=1.2, rot=0) -> str:
    t = f' transform="rotate({rot} {cx} {cy})"' if rot else ""
    return (
        f'<ellipse cx="{cx}" cy="{cy}" rx="{rx}" ry="{ry}" fill="none" '
        f'stroke="{S}" stroke-width="{sw}"{t}/>'
    )


def txt(s, x=24, y=28, size=11, italic=True, anchor="middle", weight=400) -> str:
    it = "italic" if italic else "normal"
    return (
        f'<text x="{x}" y="{y}" text-anchor="{anchor}" fill="{S}" stroke="none" '
        f'font-family="Kalam, Georgia, serif" font-style="{it}" font-size="{size}" '
        f'font-weight="{weight}">{html.escape(s)}</text>'
    )


# ---------- math ----------
def m_triangle():
    return g(ps("M24 7 L44 41 L4 41 Z", "M24 41 V28", sw=1.45))


def m_circle_r():
    return g(c(24, 24, 16) + ps("M24 24 L38 16") + c(24, 24, 1.6, fill=True)
             + txt("r", 34, 14, 9))


def m_axes():
    return g(ps("M6 38 V8 M6 38 H42", "M4 12 L6 8 L8 12", "M38 36 L42 38 L38 40",
                "M8 36 Q 18 22 32 10", sw=1.4))


def m_cube():
    return g(ps("M12 18 L24 12 L36 18 L36 32 L24 38 L12 32 Z",
                "M12 18 L24 24 L36 18", "M24 24 V38", sw=1.4))


def m_sine():
    return g(ps("M4 24 C 10 8, 14 8, 20 24 S 30 40, 36 24 S 42 8, 46 18", sw=1.5))


def m_angle():
    return g(ps("M6 38 H42", "M6 38 L28 8", "M16 38 A 12 12 0 0 1 20 24", sw=1.45)
             + txt("θ", 22, 34, 10))


def m_pentagon():
    pts = []
    for i in range(5):
        a = math.radians(-90 + i * 72)
        pts.append(f"{24+16*math.cos(a):.1f},{24+16*math.sin(a):.1f}")
    return g(ps("M" + " L".join(pts) + " Z", sw=1.45))


def m_compass():
    return g(ps("M24 6 L24 10", "M24 10 L14 40", "M24 10 L34 40",
                "M16 28 H32") + c(24, 10, 3, sw=1.4))


def m_pi():
    return g(txt("π", size=26, italic=False, weight=700))


def m_inf():
    return g(txt("∞", size=22, italic=False))


def m_frac():
    return g(
        txt("2", 16, 16, 15) + ps("M7 22 H25", sw=1.5)
        + txt("3", 16, 38, 15) + txt("= y", 30, 26, 14, anchor="start"),
        vb=56,
    )


def m_fx():
    return g(
        txt("f(x)=x", 6, 30, 15, anchor="start") + txt("2", 54, 18, 10, anchor="start"),
        vb=72,
    )


def m_sqrt():
    return g(
        ps("M4 26 L10 36 L18 10 H46", sw=1.55) + txt("a+b", 22, 30, 13, anchor="start"),
        vb=56,
    )


def m_integral():
    return g(
        txt("∫", 4, 34, 26, italic=False, anchor="start")
        + txt("f(x) dx", 20, 30, 13, anchor="start"),
        vb=80,
    )


def m_pythag():
    return g(
        ps("M8 40 L8 14 L34 40 Z", "M8 34 H14 V40", sw=1.4)
        + txt("a²+b²=c²", 4, 10, 9, anchor="start"),
        vb=56,
    )


def m_lim():
    return g(
        txt("lim", 8, 18, 12, anchor="start") + txt("x→∞", 8, 32, 11, anchor="start")
        + txt("0", 40, 26, 14, anchor="start") + ps("M34 24 H38", sw=1.3),
        vb=64,
    )


def m_euler():
    return g(
        txt("e", 6, 32, 18, anchor="start") + txt("iπ", 18, 16, 10, anchor="start")
        + txt("+1=0", 34, 32, 14, anchor="start"),
        vb=80,
    )


def m_sum_n():
    return g(
        txt("Σ", 6, 30, 22, italic=False, anchor="start")
        + txt("n=1", 8, 42, 8, italic=False, anchor="start")
        + txt("n²", 26, 26, 14, anchor="start"),
        vb=56,
    )


def m_deriv():
    return g(
        ps("M8 14 H22", "M8 34 H22", "M15 14 V34", sw=1.35)
        + txt("dy", 15, 12, 8) + txt("dx", 15, 44, 8)
        + txt("= y′", 26, 28, 13, anchor="start"),
        vb=64,
    )


def m_matrix():
    return g(
        ps("M8 8 V40", "M40 8 V40", sw=1.5)
        + txt("a", 16, 20, 12) + txt("b", 30, 20, 12)
        + txt("c", 16, 34, 12) + txt("d", 30, 34, 12)
    )


def m_gx():
    return g(txt("G(x)", 24, 30, 16))


def m_sin():
    return g(txt("sin θ", 24, 28, 14) + ps("M8 36 C 16 28, 20 28, 24 36 S 32 44, 40 36", sw=1.3), vb=56)


def m_unit():
    return g(c(24, 24, 14) + ps("M24 24 L36 16") + txt("1", 34, 14, 9) + c(24, 24, 1.5, fill=True))


def m_reals():
    return g(txt("x ∈ ℝ", 24, 28, 14))


def m_phi():
    return g(txt("φ", 24, 30, 24, italic=True, weight=700))


def m_formula(s, size=12):
    def fn():
        return g(txt(s, size=size, italic=True), vb=48)
    fn.__name__ = "mf_" + s[:12]
    return fn


def m_prism():
    return g(ps("M8 18 L24 10 L40 18 V34 L24 42 L8 34 Z",
                "M8 18 L24 26 L40 18", "M24 26 V42", sw=1.2))


def m_quad():
    return g(
        txt("x=", 2, 24, 10, anchor="start")
        + txt("b±(a−c)", 20, 14, 8, anchor="start")
        + ps("M18 20 H62", sw=1.1)
        + txt("√2a", 30, 34, 9, anchor="start"),
        vb=72,
    )


def m_vieta():
    return g(txt("x₁+x₂=−b/a", 24, 28, 9), vb=72)


def m_intln():
    return g(
        txt("∫", 2, 28, 16, italic=False, anchor="start")
        + txt("dx=ln|x|+C", 16, 26, 8, anchor="start"),
        vb=88,
    )


def m_binomial():
    return g(txt("(a+b)²=a²+2ab+b²", 24, 28, 8), vb=96)


def m_trig1():
    return g(txt("cos²x+sin²x=1", 24, 28, 9), vb=88)


def m_circle_eq():
    return g(txt("x²+y²=r²", 24, 28, 10), vb=72)


def m_cone():
    return g(
        ps("M24 6 L8 34 H40 Z", "M8 34 A 16 5 0 0 0 40 34", "M24 6 V34", sw=1.2)
        + txt("h", 28, 22, 8, anchor="start")
    )


def m_hills():
    return g(ps(
        "M4 38 C 10 38, 12 16, 18 16 S 24 38, 24 38 S 28 14, 34 14 S 42 38, 44 38",
        "M4 38 H44",
        "M16 24 C 16 20, 20 20, 20 24",
        "M32 22 C 32 18, 36 18, 36 22",
        sw=1.15,
    ))


def m_frac313():
    return g(
        txt("313", 24, 16, 10) + ps("M10 22 H38", sw=1.1) + txt("54", 24, 36, 10)
    )


def m_excos():
    return g(
        txt("e", 8, 28, 14, anchor="start") + txt("x", 18, 16, 8, anchor="start")
        + txt("cos x", 28, 28, 10, anchor="start"),
        vb=72,
    )


def m_l0():
    return g(txt("L₀=2πR", 24, 28, 11), vb=64)


def m_series():
    return g(txt("Σ 1/n² = π²/6", 24, 28, 9), vb=88)


def m_volume():
    return g(txt("V=⁴⁄₃πr³", 24, 28, 11), vb=72)


def m_ellipse():
    return g(ps("M6 24 A 18 12 0 1 0 42 24 A 18 12 0 1 0 6 24", sw=1.2)
             + txt("abπ", 24, 28, 8))


def m_similar():
    return g(ps("M8 40 L20 12 L32 40 Z", "M14 28 H26", sw=1.2)
             + txt("∼", 38, 28, 14))


def m_log():
    return g(txt("logₐ b", 24, 28, 12), vb=64)


def m_det():
    return g(
        ps("M10 10 V38", "M38 10 V38", sw=1.3)
        + txt("a b", 24, 20, 9) + txt("c d", 24, 34, 9)
    )


def m_seq():
    return g(txt("aₙ₊₁=aₙ+d", 24, 28, 9), vb=80)


def m_geom():
    return g(txt("S=a/(1−q)", 24, 28, 10), vb=72)


def m_binoms():
    return g(txt("C(n,k)", 24, 28, 11), vb=64)


def m_partial():
    return g(
        ps("M8 14 H22", "M8 34 H22", "M15 14 V34", sw=1.15)
        + txt("∂f", 15, 12, 7) + txt("∂x", 15, 44, 7)
        + txt("= fₓ", 26, 28, 11, anchor="start"),
        vb=64,
    )


def m_ineq():
    return g(txt("0 < x < 1", 24, 28, 11), vb=64)


def m_mapsto():
    return g(txt("f: ℝ→ℝ", 24, 28, 11), vb=64)


MATH_FNS = [
    m_triangle, m_circle_r, m_axes, m_cube, m_sine, m_angle, m_pentagon, m_compass,
    m_pi, m_inf, m_frac, m_fx, m_sqrt, m_integral, m_pythag, m_lim, m_euler,
    m_sum_n, m_deriv, m_matrix, m_gx, m_sin, m_unit, m_reals, m_phi,
    m_prism, m_quad, m_vieta, m_intln, m_binomial, m_trig1, m_circle_eq, m_cone,
    m_hills, m_frac313, m_excos, m_l0, m_series, m_volume, m_ellipse, m_similar,
    m_log, m_det, m_seq, m_geom, m_binoms, m_partial, m_ineq, m_mapsto,
    m_formula("∇²φ=0", 11), m_formula("n!=Γ(n+1)", 10),
    m_formula("e^{iθ}=cis θ", 9), m_formula("Σ 1/n = ∞", 10),
    m_formula("ζ(2)=π²/6", 10), m_formula("a×b", 12),
    m_formula("det A≠0", 11), m_formula("∀x ∃y", 11),
    m_formula("ℕ⊂ℤ⊂ℚ", 10), m_formula("tanh x", 12),
    m_formula("(fg)′=f′g+fg′", 8), m_formula("∫eˣ dx=eˣ", 10),
    m_formula("Δx→0", 12), m_formula("‖v‖", 14),
    m_formula("AᵀA", 13), m_formula("λI−A", 12),
    m_formula("P(A|B)", 11), m_formula("μ, σ²", 12),
    m_formula("χ²", 16), m_formula("n→∞", 13),
    m_formula("∇×F", 12), m_formula("iℏ ∂ψ/∂t", 10),
    m_formula("cos(a+b)", 10), m_formula("sin 2x", 12),
    m_formula("tan⁻¹ x", 11), m_formula("log xy", 12),
    m_formula("aⁿ aᵐ=aⁿ⁺ᵐ", 9), m_formula("√2 ≈ 1.41", 10),
    m_formula("φ=(1+√5)/2", 9), m_formula("e≈2.718", 11),
    m_formula("π≈3.1415", 10), m_formula("0.999…=1", 10),
    m_formula("∑ k = n(n+1)/2", 8), m_formula("Cₙᵏ", 13),
    m_formula("x̄", 16), m_formula("f∘g", 13),
    m_formula("ker T", 12), m_formula("im T", 12),
    m_formula("ℝⁿ", 14), m_formula("S¹", 14),
    m_formula("a ⊥ b", 12), m_formula("△ABC", 12),
    m_formula("≅", 16), m_formula("∝", 16),
    m_formula("±", 16), m_formula("∴", 16),
    m_formula("∵", 16), m_formula("≈", 16),
    m_formula("≠", 16), m_formula("≤ ≥", 13),
    m_formula("mod n", 11), m_formula("gcd", 13),
    m_formula("lcm", 13), m_formula("prime?", 11),
    m_formula("9.8 m/s²", 10), m_formula("∞/∞", 13),
    m_formula("0!", 14), m_formula("1=0.9…", 11),
]


# ---------- programming ----------
def p_tag():
    return g(ps("M18 12 L8 24 L18 36", "M30 12 L40 24 L30 36", "M28 10 L20 38"))


def p_curly():
    return g(ps("M16 8 C 8 8, 8 18, 14 24 C 8 30, 8 40, 16 40",
                "M32 8 C 40 8, 40 18, 34 24 C 40 30, 40 40, 32 40"))


def p_term():
    return g(ps("M6 10 H42 V38 H6 Z", "M6 10 H42 V16 H6 Z", "M12 24 L18 28 L12 32",
                "M22 32 H32") + c(12, 13, 1.1, fill=True) + c(16.5, 13, 1.1, fill=True)
             + c(21, 13, 1.1, fill=True))


def p_git():
    return g(ps("M18 10 V30", "M18 24 L32 16") + c(18, 10, 3.2) + c(18, 30, 3.2)
             + c(32, 16, 3.2))


def p_bug():
    return g(ps("M16 20 C 16 12, 32 12, 32 20 V30 C 32 36, 16 36, 16 30 Z",
                "M14 16 L10 12", "M34 16 L38 12", "M14 28 L8 28", "M34 28 L40 28",
                "M24 12 V8", "M20 22 H28") + c(20, 22, 1.1, fill=True)
             + c(28, 22, 1.1, fill=True))


def p_laptop():
    return g(ps("M10 14 H38 V30 H10 Z", "M6 30 H42 L44 36 H4 Z", "M18 20 H30"))


def p_chip():
    return g(ps("M14 14 H34 V34 H14 Z", "M14 14 L10 14", "M14 24 L10 24",
                "M14 34 L10 34", "M34 14 L38 14", "M34 24 L38 24", "M34 34 L38 34",
                "M18 14 V10", "M24 14 V10", "M30 14 V10", "M18 34 V38",
                "M24 34 V38", "M30 34 V38") + c(24, 24, 4, sw=1.3))


def p_arr():
    return g(ps("M12 12 H36 V36 H12 Z", "M18 20 H30", "M18 28 H26"))


def p_fn():
    return g(txt("fn()", size=14, italic=True))


def p_bin():
    return g(txt("01", size=16, italic=False, weight=700))


def p_hash():
    return g(ps("M16 14 V36", "M32 14 V36", "M12 20 H36", "M12 30 H36"))


def p_lambda():
    return g(txt("λ", size=26, italic=True))


def p_prompt():
    return g(ps("M10 18 L20 24 L10 30", "M24 30 H38"))


def p_db():
    return g(ps("M10 14 C 10 10, 38 10, 38 14 V34 C 38 38, 10 38, 10 34 Z",
                "M10 14 C 10 18, 38 18, 38 14", "M10 24 C 10 28, 38 28, 38 24"))


def p_wifi():
    return g(ps("M12 28 A 16 16 0 0 1 36 28", "M17 32 A 9 9 0 0 1 31 32")
             + c(24, 37, 1.8, fill=True))


def p_semi():
    return g(txt("};", size=20, italic=False, weight=700))


def p_if():
    return g(txt("if", size=16, italic=True))


PROG_FNS = [
    p_tag, p_curly, p_term, p_git, p_bug, p_laptop, p_chip, p_arr, p_fn, p_bin,
    p_hash, p_lambda, p_prompt, p_db, p_wifi, p_semi, p_if,
    m_formula("</>", 16), m_formula("for", 14), m_formula("git", 14),
    m_formula("0xFF", 13), m_formula("null", 13), m_formula("=>", 18),
    m_formula("const", 12), m_formula("async", 12), m_formula("await", 12),
    m_formula("class", 12), m_formula("import", 12), m_formula("true", 13),
    m_formula("false", 12), m_formula("!=", 16), m_formula("===", 14),
    m_formula("[]", 18), m_formula("{}", 18), m_formula("def", 13),
    m_formula("let", 14), m_formula("var", 14), m_formula("#include", 10),
    m_formula("main()", 12), m_formula("TODO", 12), m_formula("err", 13),
    m_formula("try", 14), m_formula("catch", 12), m_formula("&&", 16),
    m_formula("||", 16), m_formula("++", 16), m_formula("--", 16),
    m_formula("npm", 13), m_formula("rust", 13), m_formula("dart", 13),
    m_formula("sql", 14), m_formula("HTTP", 12), m_formula("JSON", 12),
    m_formula("nil", 14), m_formula("NaN", 13), m_formula("O(n)", 12),
    m_formula("O(1)", 12), m_formula("map", 13), m_formula("fold", 13),
    m_formula("self", 13), m_formula("this", 13), m_formula("fn", 14),
    m_formula("</html>", 10), m_formula("ssh", 13), m_formula("404", 14),
]


# ---------- dating ----------
def d_heart():
    return g(ps("M24 40 C 10 28, 6 18, 16 12 C 22 8, 24 14, 24 14 "
                "C 24 14, 26 8, 32 12 C 42 18, 38 28, 24 40"))


def d_hearts():
    return g(ps("M18 28 C 10 22, 8 16, 14 12 C 17 10, 19 13, 19 13 "
                "C 19 13, 20 10, 24 12 C 30 16, 28 22, 18 28",
                "M30 36 C 20 28, 18 20, 26 16 C 30 13, 32 17, 32 17 "
                "C 32 17, 34 13, 38 16 C 46 20, 44 28, 30 36", sw=1.45))


def d_letter():
    return g(ps("M8 14 H40 V36 H8 Z", "M8 14 L24 26 L40 14",
                "M24 26 L24 22") + c(24, 30, 2.2))


def d_rose():
    return g(ps("M24 8 C 32 8, 34 18, 24 22 C 14 18, 16 8, 24 8",
                "M24 22 C 30 22, 30 30, 24 32 C 18 30, 18 22, 24 22",
                "M24 32 V42", "M24 36 C 16 34, 14 40, 18 42",
                "M24 34 C 32 32, 34 38, 30 40", sw=1.4))


def d_ring():
    return g(c(24, 28, 12) + ps("M24 8 L28 16 H20 Z", "M20 16 H28", sw=1.45))


def d_glasses():
    return g(ps("M8 22 Q 14 14, 20 22 Q 14 30, 8 22 Z",
                "M28 22 Q 34 14, 40 22 Q 34 30, 28 22 Z", "M20 22 H28", sw=1.4))


def d_moon():
    return g(ps("M30 8 C 18 10, 12 22, 18 34 C 28 42, 40 34, 36 24 "
                "C 30 28, 24 22, 30 8", sw=1.5))


def d_star():
    return g(ps("M24 6 L27 18 H40 L30 26 L34 40 L24 32 L14 40 L18 26 L8 18 H21 Z",
                sw=1.35))


def d_bubble():
    return g(ps("M8 10 H40 V30 H20 L12 38 V30 H8 Z", "M16 20 H32", "M16 24 H26"))


def d_flower():
    petals = []
    for i in range(5):
        a = math.radians(-90 + i * 72)
        x, y = 24 + 12 * math.cos(a), 24 + 12 * math.sin(a)
        petals.append(c(x, y, 6, sw=1.35))
    return g("".join(petals) + c(24, 24, 4, sw=1.4))


def d_key():
    return g(c(16, 24, 8) + ps("M24 24 H42", "M42 24 V30", "M36 24 V28", sw=1.45)
             + c(16, 24, 3.2, sw=1.3))


def d_fly():
    return g(ps("M24 24 L16 12 C 8 16, 10 28, 20 28",
                "M24 24 L32 12 C 40 16, 38 28, 28 28",
                "M24 16 V36", "M20 32 L24 36 L28 32", sw=1.4))


def d_arrow():
    return g(ps("M6 24 H42", "M34 16 L42 24 L34 32",
                "M18 24 C 18 16, 24 16, 24 24 C 24 32, 18 32, 18 24", sw=1.4))


def d_lips():
    return g(ps("M8 24 C 16 16, 32 16, 40 24 C 32 32, 16 32, 8 24",
                "M8 24 H40", sw=1.45))


def d_note():
    return g(ps("M28 12 V32", "M28 12 H38 V18 H28") + c(22, 32, 6, sw=1.4))


def d_spark():
    return g(ps("M24 6 V18", "M24 30 V42", "M6 24 H18", "M30 24 H42",
                "M12 12 L18 18", "M30 18 L36 12", "M12 36 L18 30", "M30 30 L36 36",
                sw=1.35))


DATE_FNS = [
    d_heart, d_hearts, d_letter, d_rose, d_ring, d_glasses, d_moon, d_star,
    d_bubble, d_flower, d_key, d_fly, d_arrow, d_lips, d_note, d_spark,
    m_formula("xoxo", 12), m_formula("miss u", 11), m_formula("♥", 18),
    m_formula("kiss", 13), m_formula("date?", 12), m_formula("uwu", 13),
    m_formula("ily", 14), m_formula("soon", 13), m_formula("7pm", 13),
    m_formula("call me", 11), m_formula("♡", 18), m_formula("hi", 14),
]


# ---------- work ----------
def w_case():
    return g(ps("M8 18 H40 V38 H8 Z", "M18 18 V14 H30 V18", "M8 26 H40"))


def w_clock():
    return g(c(24, 24, 16) + ps("M24 24 V14", "M24 24 L32 28") + c(24, 24, 1.5, fill=True))


def w_cal():
    return g(ps("M10 12 H38 V40 H10 Z", "M10 20 H38", "M18 8 V16", "M30 8 V16",
                "M16 26 H20", "M24 26 H28", "M32 26 H36", "M16 32 H20", "M24 32 H28"))


def w_check():
    return g(ps("M8 14 H16 V22 H8 Z", "M10 18 L13 21 L20 12",
                "M8 28 H16 V36 H8 Z", "M22 18 H40", "M22 32 H36"))


def w_pen():
    return g(ps("M12 36 L16 28 L36 8 L40 12 L20 32 Z", "M16 28 L20 32",
                "M12 36 L8 40", sw=1.4))


def w_bars():
    return g(ps("M8 40 V18 H16 V40", "M20 40 V10 H28 V40", "M32 40 V24 H40 V40",
                "M6 40 H44"))


def w_coffee():
    return g(ps("M12 16 H32 V34 C 32 40, 12 40, 12 34 Z", "M32 20 H38 C 42 20, 42 30, 38 30 H32",
                "M16 10 C 18 6, 22 6, 20 12", "M24 10 C 26 6, 30 6, 28 12", sw=1.4))


def w_folder():
    return g(ps("M8 16 L16 16 L20 12 H40 V36 H8 Z", sw=1.45))


def w_clip():
    return g(ps("M18 32 V16 C 18 10, 30 10, 30 16 V34 C 30 40, 18 40, 18 34 V20",
                sw=1.55))


def w_mail():
    return g(ps("M8 14 H40 V36 H8 Z", "M8 14 L24 26 L40 14"))


def w_pie():
    return g(c(24, 24, 16) + ps("M24 24 L24 8", "M24 24 L36 30"))


def w_build():
    return g(ps("M10 40 V16 L24 8 L38 16 V40 Z", "M18 40 V28 H30 V40",
                "M16 20 H20", "M28 20 H32", "M16 26 H20", "M28 26 H32"))


def w_pin():
    return g(c(24, 16, 8) + ps("M24 24 V40", "M20 40 H28") + c(24, 16, 3, sw=1.3))


def w_calc():
    return g(ps("M12 8 H36 V40 H12 Z", "M16 12 H32 V18 H16 Z",
                "M16 24 H20 V28 H16 Z", "M22 24 H26 V28 H22 Z",
                "M28 24 H32 V28 H28 Z", "M16 32 H20 V36 H16 Z",
                "M22 32 H26 V36 H22 Z", "M28 32 H32 V36 H28 Z"))


def w_lamp():
    return g(ps("M24 40 V26", "M16 26 C 16 14, 32 14, 32 26 Z",
                "M18 40 H30", "M20 14 L16 8", "M28 14 L32 8"))


def w_doc():
    return g(ps("M14 8 H28 L36 16 V40 H14 Z", "M28 8 V16 H36",
                "M18 22 H32", "M18 28 H32", "M18 34 H26"))


WORK_FNS = [
    w_case, w_clock, w_cal, w_check, w_pen, w_bars, w_coffee, w_folder, w_clip,
    w_mail, w_pie, w_build, w_pin, w_calc, w_lamp, w_doc,
    m_formula("ASAP", 12), m_formula("Q3", 14), m_formula("OKR", 13),
    m_formula("9:00", 12), m_formula("done", 13), m_formula("WIP", 13),
    m_formula("LGTM", 12), m_formula("FYI", 13), m_formula("EOD", 13),
    m_formula("sync", 13), m_formula("P0", 14), m_formula("SLA", 13),
]


# ---------- space ----------
def s_saturn():
    return g(
        ell(24, 24, 22, 6.4, 1.35, -22)
        + ell(24, 24, 18.5, 5.2, 1.1, -22)
        + c(24, 24, 10.2, sw=1.4)
        + ps("M16 22 C 20 20, 28 20, 32 22", sw=1.15)
        + c(42, 13, 2.3, sw=1.2),
        vb=48,
    )


def s_solarsys():
    orbs = "".join(ell(36, 36, rx, ry, 1.0) for rx, ry in (
        (9, 8), (14, 12), (19, 16), (25, 21), (32, 26),
    ))
    return g(
        c(36, 36, 4.2, sw=1.4)
        + c(36, 36, 2.2, fill=True)
        + orbs
        + c(45, 36, 1.15, fill=True)
        + c(36, 24, 1.45, fill=True)
        + c(55, 36, 1.7, fill=True)
        + c(36, 15, 1.5, fill=True)
        + ell(68, 36, 3.4, 1.15, 1.05, -18)
        + c(68, 36, 1.7, sw=1.15),
        vb=72,
    )


def s_rocket():
    return g(
        ps("M24 4 L31 18 V30 L24 26 L17 30 V18 Z",
           "M17 30 L12 40 L17 33", "M31 30 L36 40 L31 33",
           "M21 34 L24 42 L27 34", sw=1.3)
        + c(24, 16, 2.3, sw=1.2)
    )


def s_earth():
    return g(
        c(24, 24, 14, sw=1.4)
        + ps("M12 18 C 16 16, 22 20, 28 18 C 32 22, 30 26, 24 26 C 18 26, 14 22, 12 18",
             "M16 32 C 20 30, 26 34, 34 30",
             "M24 10 C 18 16, 17 30, 24 38",
             "M24 10 C 30 16, 31 30, 24 38", sw=1.2)
    )


def s_crescent():
    return g(ps("M32 10 C 18 12, 12 24, 16 36 C 28 40, 40 32, 36 22 "
                "C 30 26, 24 20, 32 10", sw=1.45))


def s_star4():
    return g(ps("M24 4 L27 20 L44 24 L27 28 L24 44 L21 28 L4 24 L21 20 Z", sw=1.3))


def s_sat():
    return g(
        ps("M6 18 H16 V30 H6 Z", "M32 18 H42 V30 H32 Z",
           "M16 24 H32", "M24 14 V18", "M24 30 V36", sw=1.3)
        + c(24, 24, 5)
        + ps("M22 22 H26 V26 H22 Z", sw=1.15)
    )


def s_helm():
    return g(
        c(24, 20, 13, sw=1.4)
        + ps("M11 20 H37", "M16 33 H32", "M18 33 V38 H30 V33", sw=1.25)
        + c(24, 20, 7.5, sw=1.2)
    )


def s_comet():
    return g(
        c(34, 14, 5.5, sw=1.35)
        + ps("M30 18 L6 42", "M32 20 L14 38", "M28 16 L10 32",
             "M36 20 L22 40", sw=1.25)
    )


def s_orbit():
    return g(
        c(20, 24, 7, sw=1.35)
        + ell(20, 24, 18, 11, 1.2, -12)
        + c(36, 20, 2.4, sw=1.2)
    )


def s_ufo():
    return g(
        ps("M10 26 C 10 20, 38 20, 38 26 C 38 33, 10 33, 10 26",
           "M18 20 C 18 12, 30 12, 30 20", sw=1.3)
        + c(16, 28, 1.2, fill=True) + c(24, 29.5, 1.2, fill=True)
        + c(32, 28, 1.2, fill=True)
    )


def s_scope():
    return g(
        ps("M14 36 L24 24", "M22 22 L42 10 L44 15 L24 27 Z",
           "M16 34 L8 44", "M20 36 L12 44", "M10 44 H18", sw=1.3)
        + c(24, 24, 3.2, sw=1.2)
    )


def s_const():
    return g(
        c(8, 20, 1.7, fill=True) + c(18, 12, 1.7, fill=True)
        + c(30, 14, 1.7, fill=True) + c(40, 22, 1.7, fill=True)
        + c(34, 34, 1.7, fill=True) + c(20, 32, 1.7, fill=True)
        + c(12, 28, 1.7, fill=True)
        + ps("M8 20 L18 12 L30 14 L40 22 L34 34 L20 32 L12 28", sw=1.15)
    )


def s_galaxy():
    return g(
        ps("M8 28 C 10 12, 28 10, 36 20 C 40 28, 28 30, 22 24",
           "M40 20 C 38 36, 20 38, 12 28 C 8 20, 20 18, 26 24", sw=1.25)
        + c(24, 24, 2.6, fill=True)
    )


def s_flag():
    return g(
        ps("M16 42 L16 8 L38 14 L16 22", "M12 42 H22", sw=1.3)
        + c(24, 6, 2, fill=True)
    )


def s_planet():
    return g(
        c(24, 24, 13, sw=1.4)
        + ps("M12 18 C 18 14, 30 14, 36 18", "M12 30 C 18 34, 30 34, 36 30", sw=1.2)
    )


def s_phases():
    return g(
        c(8, 24, 6, sw=1.2)
        + ps("M22 18 A 6 6 0 1 0 22 30 Z", sw=1.2)
        + c(36, 24, 6, sw=1.2) + ps("M36 18 A 6 6 0 0 1 36 30", sw=1.2)
        + c(50, 24, 6, fill=True),
        vb=60,
    )


def s_dipper():
    return g(
        c(6, 28, 1.6, fill=True) + c(14, 22, 1.6, fill=True)
        + c(24, 20, 1.6, fill=True) + c(32, 26, 1.6, fill=True)
        + c(38, 16, 1.6, fill=True) + c(46, 10, 1.6, fill=True) + c(42, 4, 1.6, fill=True)
        + ps("M6 28 L14 22 L24 20 L32 26 L38 16 L46 10 L42 4", sw=1.15),
        vb=56,
    )


SPACE_FNS = [
    s_saturn, s_solarsys, s_rocket, s_earth, s_crescent, s_star4, s_sat, s_helm,
    s_comet, s_orbit, s_ufo, s_scope, s_const, s_galaxy, s_flag, s_planet,
    s_phases, s_dipper, d_star, d_spark, s_saturn, s_solarsys, s_saturn,
    m_formula("ISS", 13), m_formula("c=3·10⁸", 10), m_formula("AU", 14),
    m_formula("NASA", 12), m_formula("G=6.67·10⁻¹¹", 8), m_formula("ly", 14),
    m_formula("v=H₀d", 11), m_formula("Mₑ", 14), m_formula("∞", 16),
    m_formula("0g", 14), m_formula("LEO", 13), m_formula("apogee", 11),
]


# ---------- physics ----------
def ph_cube():
    return g(ps("M12 18 L24 12 L36 18 L36 32 L24 38 L12 32 Z",
                "M12 18 L24 24 L36 18", "M24 24 V38", sw=1.35))


def ph_cone():
    return g(
        ps("M24 6 L8 34 H40 Z", "M8 34 A 16 5 0 0 0 40 34", "M24 6 V34", sw=1.25)
        + txt("h", 28, 22, 8, anchor="start")
    )


def ph_sphere():
    return g(c(24, 24, 14, sw=1.35) + ell(24, 24, 14, 5, 1.15))


def ph_cyl():
    return g(
        ell(24, 10, 12, 4, 1.25)
        + ps("M12 10 V32", "M36 10 V32", sw=1.3)
        + ell(24, 32, 12, 4, 1.25)
    )


def ph_pendulum():
    return g(
        ps("M8 6 H40", "M24 6 V10", "M24 10 L16 36", sw=1.3)
        + c(16, 39, 4.0, sw=1.2)
        + ps("M24 10 L32 32", sw=1.05)
    )


def ph_atom():
    return g(
        c(24, 24, 3.0, fill=True)
        + ell(24, 24, 16, 7, 1.15, -20)
        + ell(24, 24, 16, 7, 1.15, 25)
        + ell(24, 24, 7, 16, 1.15, 8)
        + c(38, 20, 1.7, fill=True)
    )


def ph_circuit():
    return g(
        ps("M4 24 H12", "M12 16 V32", "M16 16 V32", "M16 24 H24",
           "M24 20 H34", "M24 28 H34", "M34 24 H44", sw=1.25)
        + txt("e", 8, 15, 8)
        + txt("R", 29, 16, 8)
    )


def ph_spring():
    return g(ps("M6 24 H12 L14 14 L18 34 L22 14 L26 34 L30 14 L34 24 H42", sw=1.3))


def ph_magnet():
    return g(
        ps("M10 10 H20 V38 H10 Z", "M28 10 H38 V38 H28 Z",
           "M20 14 C 24 6, 24 6, 28 14",
           "M20 34 C 24 42, 24 42, 28 34", sw=1.25)
        + txt("N", 15, 26, 8)
        + txt("S", 33, 26, 8)
    )


def ph_projectile():
    return g(
        ps("M6 40 V8", "M6 40 H44", "M6 40 Q 22 6, 44 26", sw=1.25)
        + c(28, 16, 2.2, fill=True)
        + txt("v0", 16, 14, 8, anchor="start")
    )


def ph_inclined():
    return g(
        ps("M4 40 H44", "M4 40 L34 12", "M34 12 V40", sw=1.3)
        + ps("M16 28 L22 24 L26 30 L20 34 Z", sw=1.2)
        + txt("a", 14, 40, 8)
        + txt("mg", 28, 20, 8, anchor="start")
    )


def ph_lens():
    return g(
        ps("M24 6 C 34 14, 34 34, 24 42 C 14 34, 14 14, 24 6",
           "M4 24 H44", "M38 20 L44 24 L38 28", sw=1.25)
    )


def ph_wave():
    return g(
        ps("M4 24 C 10 8, 14 8, 20 24 S 30 40, 36 24 S 44 8, 46 18",
           "M4 24 H46", sw=1.25)
        + txt("L", 22, 40, 9)
    )


def ph_vectors():
    return g(
        ps("M8 40 V8", "M8 40 H42", "M8 40 L34 12", sw=1.3)
        + ps("M8 8 L12 14 M8 8 L4 14", "M42 40 L36 36 M42 40 L36 44",
             "M34 12 L28 14 M34 12 L32 18", sw=1.15)
        + txt("F", 36, 12, 8, anchor="start")
    )


def ph_prism():
    return g(
        ps("M18 10 L30 10 L36 38 H12 Z", sw=1.3)
        + ps("M4 20 L18 24", "M30 24 L44 16", "M30 28 L44 32", sw=1.2)
        + txt("n", 24, 28, 8)
    )


def ph_ohm():
    return g(
        ps("M4 24 H14", "M14 18 H34 V30 H14 Z", "M34 24 H44", sw=1.3)
        + txt("R", 24, 26, 10)
    )


def ph_lever():
    return g(
        ps("M4 28 H44", "M24 28 L24 40 L20 40", sw=1.3)
        + ps("M10 28 V18 H16 V28", "M34 28 V14 H40 V28", sw=1.2)
        + txt("F", 13, 14, 8)
    )


def ph_pulley():
    return g(
        c(24, 12, 7, sw=1.3)
        + ps("M17 12 V36", "M31 12 V28 H38", sw=1.25)
        + ps("M12 36 H22 V42 H12 Z", "M38 28 V36 H44", sw=1.2)
    )


def ph_thermo():
    return g(
        ps("M20 8 H28 V32 H20 Z", "M22 32 V40 H26 V32", sw=1.3)
        + ps("M22 14 H26", "M22 20 H26", "M22 26 H26", sw=1.15)
    )


def ph_fma():
    return g(
        ps("M8 36 H40", "M14 36 V20 H28 V36", sw=1.3)
        + ps("M28 26 H40 L36 22 M40 26 L36 30", sw=1.2)
        + txt("F", 34, 18, 9)
    )


def ph_cap():
    return g(ps("M4 24 H18", "M18 12 V36", "M24 12 V36", "M24 24 H44", sw=1.35))


def ph_battery():
    return g(
        ps("M4 24 H14", "M14 14 V34", "M20 18 V30", "M20 24 H30",
           "M30 14 V34", "M36 18 V30", "M36 24 H44", sw=1.3)
        + txt("+", 10, 16, 8)
    )


def ph_mirror():
    return g(
        ps("M30 8 C 18 14, 18 34, 30 40", "M8 16 L22 22", "M8 32 L22 26",
           "M22 22 L18 18 M22 22 L16 24", sw=1.25)
    )


def ph_fbd():
    return g(
        ps("M16 20 H32 V36 H16 Z", "M24 20 V8 L20 12 M24 8 L28 12",
           "M24 36 V44 L20 40 M24 44 L28 40", "M16 28 H6 L10 24 M6 28 L10 32",
           sw=1.25)
        + txt("N", 28, 12, 7, anchor="start")
        + txt("mg", 28, 46, 7, anchor="start")
    )


def ph_circle_v():
    return g(
        c(24, 24, 13, sw=1.3)
        + ps("M24 11 L24 8", "M37 24 H42 L38 20 M42 24 L38 28", sw=1.2)
        + txt("v", 40, 16, 8)
        + c(24, 24, 1.5, fill=True)
    )


def ph_standwave():
    return g(ps(
        "M4 24 C 10 8, 14 8, 20 24 S 30 40, 36 24 S 42 8, 44 16",
        "M4 24 C 10 40, 14 40, 20 24 S 30 8, 36 24 S 42 40, 44 32",
        sw=1.2,
    ))


def ph_field():
    return g(
        ps("M10 10 H20 V38 H10 Z", sw=1.3)
        + txt("N", 15, 26, 8)
        + ps("M24 12 C 34 16, 40 20, 44 14", "M24 24 C 34 24, 40 24, 44 24",
             "M24 36 C 34 32, 40 28, 44 34", sw=1.15)
    )


def ph_collision():
    return g(
        c(16, 24, 7, sw=1.3) + c(34, 24, 7, sw=1.3)
        + ps("M4 24 H8 L6 20 M8 24 L6 28", "M42 24 H46 L44 20 M46 24 L44 28", sw=1.2)
    )


def ph_vessel():
    return g(
        ps("M12 10 V38 H36 V10", "M14 28 H34", sw=1.3)
        + txt("h", 40, 30, 8, anchor="start")
    )


def ph_solenoid():
    return g(ps(
        "M6 24 C 10 12, 14 12, 18 24 S 26 36, 30 24 S 38 12, 42 20",
        "M8 16 H40", "M8 32 H40",
        sw=1.25,
    ))


def ph_rays():
    return g(
        c(10, 24, 3.2, fill=True)
        + ps("M14 24 H42 L38 20 M42 24 L38 28",
             "M14 24 L40 12 L36 14", "M14 24 L40 36 L36 34", sw=1.25)
    )


def ph_balance():
    return g(
        ps("M8 22 H40", "M24 22 V38 H16", "M10 22 V16 H18 V22",
           "M30 22 V14 H38 V22", sw=1.25)
    )


def ph_charge():
    return g(
        c(16, 24, 8, sw=1.3) + c(34, 24, 8, sw=1.3)
        + txt("+", 16, 28, 12, italic=False) + txt("−", 34, 28, 12, italic=False)
    )


def ph_ac():
    return g(
        c(24, 24, 14, sw=1.3)
        + ps("M12 24 C 16 12, 20 12, 24 24 S 32 36, 36 24", sw=1.25)
    )


def ph_switch():
    return g(ps("M4 24 H16", "M16 24 L30 14", "M32 24 H44", sw=1.35)
             + c(16, 24, 2.0, fill=True) + c(32, 24, 2.0, fill=True))


def ph_nucleus():
    return g(
        c(20, 22, 5, sw=1.2) + c(28, 22, 5, sw=1.2) + c(24, 30, 5, sw=1.2)
        + c(20, 22, 1.6, fill=True) + c(28, 22, 1.6, fill=True)
    )


def ph_photon():
    return g(
        ps("M6 24 C 12 12, 16 12, 22 24 S 32 36, 38 24 S 44 14, 46 18", sw=1.3)
        + ps("M36 12 L42 8 L40 16", sw=1.2)
    )


PHYS_FNS = [
    ph_cube, ph_cone, ph_sphere, ph_cyl, ph_pendulum, ph_atom, ph_circuit,
    ph_spring, ph_magnet, ph_projectile, ph_inclined, ph_lens, ph_wave,
    ph_vectors, ph_prism, ph_ohm, ph_lever, ph_pulley, ph_thermo, ph_fma,
    ph_cap, ph_battery, ph_mirror, ph_fbd, ph_circle_v, ph_standwave,
    ph_field, ph_collision, ph_vessel, ph_solenoid, ph_rays, ph_balance,
    ph_charge, ph_ac, ph_switch, ph_nucleus, ph_photon,
    ph_cube, ph_cone, ph_sphere, ph_atom, ph_pendulum, ph_spring, ph_wave,
    ph_lens, ph_magnet, ph_circuit, ph_inclined, ph_vectors, ph_prism,
    m_formula("F=ma", 13), m_formula("E=mc²", 12), m_formula("Ek=mv²/2", 10),
    m_formula("Ep=mgh", 11), m_formula("p=mv", 13), m_formula("U=IR", 13),
    m_formula("P=IU", 13), m_formula("F=−kx", 12), m_formula("g≈9.8", 12),
    m_formula("v=v0+at", 10), m_formula("s=vt", 13), m_formula("A=Fs", 13),
    m_formula("N=A/t", 12), m_formula("N=Fv", 13), m_formula("I=q/t", 12),
    m_formula("I=U/R", 12), m_formula("q=CU", 13), m_formula("P=I²R", 12),
    m_formula("W=CU²/2", 10), m_formula("F=GMm/r²", 9), m_formula("p=rgh", 12),
    m_formula("FA=rgV", 11), m_formula("P=F/S", 12), m_formula("M=Fd", 13),
    m_formula("T=2π√(l/g)", 9), m_formula("T=2π√(m/k)", 9), m_formula("w=2πf", 12),
    m_formula("v=fL", 13), m_formula("an=v²/r", 11), m_formula("pV=nRT", 11),
    m_formula("Q=cm dT", 10), m_formula("dU=Q−A", 10), m_formula("E=hf", 13),
    m_formula("n=c/v", 12), m_formula("1/F=1/d+1/f", 8), m_formula("D=1/F", 12),
    m_formula("F=qvB", 12), m_formula("F=IBl", 12), m_formula("e=Blv", 12),
    m_formula("R=rl/S", 11), m_formula("C=ee0S/d", 9), m_formula("E=kq/r²", 10),
    m_formula("A=qU", 13), m_formula("L=h/p", 12), m_formula("c=3·10^8", 10),
    m_formula("h=6.63·10−34", 8), m_formula("R=8.31", 12), m_formula("k=9·10^9", 10),
    m_formula("v²=v0²+2as", 9), m_formula("s=v0t+½at²", 9), m_formula("Ep=kx²/2", 10),
    m_formula("E=Ek+Ep", 10), m_formula("p=const", 11), m_formula("f=1/T", 12),
    m_formula("I=e/(R+r)", 10), m_formula("P=U²/R", 11), m_formula("W=LI²/2", 10),
    m_formula("Q=Lm", 13), m_formula("eff=A/Q", 11), m_formula("n1 sini=n2 sinr", 8),
]


NACRE_DARK = ["#b8f0dc", "#9ad8ff", "#d4b8ff", "#ffb0d8", "#ffd89a", "#b0f0c8", "#a8c8ff", "#f0c8ff"]
NACRE_LIGHT = ["#2a6a5c", "#245a78", "#5a3a78", "#7a3858", "#6a5420", "#2a6848", "#2a4870", "#5a3860"]


def nacre(shift: int = 0) -> tuple[list[str], list[str]]:
    d = NACRE_DARK[shift:] + NACRE_DARK[:shift]
    l = NACRE_LIGHT[shift:] + NACRE_LIGHT[:shift]
    return d, l


THEMES = {
    "math": {
        "title": "Математика",
        "title_en": "Math",
        "bg_dark": "radial-gradient(120% 90% at 28% 0%, #152028 0%, #0a1012 58%, #0c1418 100%)",
        "bg_light": "radial-gradient(120% 90% at 28% 0%, #f4f7f4 0%, #eef1ee 55%, #e4ece8 100%)",
        "grad_dark": nacre(0)[0],
        "grad_light": nacre(0)[1],
        "fns": MATH_FNS,
        "skip": 0.02,
        "scale": (0.72, 1.22),
        "rot": 14,
        "cols": 10,
        "rows": 22,
        "seed": 11,
        "dense": True,
    },
    "physics": {
        "title": "Физика",
        "title_en": "Physics",
        "bg_dark": "radial-gradient(120% 90% at 70% 0%, #141c28 0%, #0a1014 58%, #0c1218 100%)",
        "bg_light": "radial-gradient(120% 90% at 70% 0%, #f2f5f8 0%, #eef1f4 55%, #e4eaf0 100%)",
        "grad_dark": nacre(3)[0],
        "grad_light": nacre(3)[1],
        "fns": PHYS_FNS,
        "skip": 0.02,
        "scale": (0.72, 1.22),
        "rot": 14,
        "cols": 10,
        "rows": 22,
        "seed": 29,
        "dense": True,
    },
    "code": {
        "title": "Программирование",
        "title_en": "Code",
        "bg_dark": "radial-gradient(120% 90% at 80% 0%, #12241f 0%, #0c1212 50%, #10181c 100%)",
        "bg_light": "radial-gradient(120% 90% at 80% 0%, #eef8f5 0%, #eef4f3 52%, #e0eeea 100%)",
        "grad_dark": nacre(1)[0],
        "grad_light": nacre(1)[1],
        "fns": PROG_FNS,
        "skip": 0.10,
        "scale": (2.15, 3.20),
        "rot": 16,
        "cols": 5,
        "rows": 11,
        "seed": 23,
    },
    "date": {
        "title": "Знакомства",
        "title_en": "Dating",
        "bg_dark": "radial-gradient(120% 90% at 12% 0%, #24141c 0%, #100c10 50%, #1a1016 100%)",
        "bg_light": "radial-gradient(120% 90% at 12% 0%, #fbf0f5 0%, #f6eef2 52%, #f0e4ec 100%)",
        "grad_dark": nacre(2)[0],
        "grad_light": nacre(2)[1],
        "fns": DATE_FNS,
        "skip": 0.08,
        "scale": (2.10, 3.25),
        "rot": 20,
        "cols": 5,
        "rows": 11,
        "seed": 41,
    },
    "work": {
        "title": "Работа",
        "title_en": "Work",
        "bg_dark": "radial-gradient(120% 90% at 70% 10%, #1c1810 0%, #0e0c0a 50%, #14120e 100%)",
        "bg_light": "radial-gradient(120% 90% at 70% 10%, #f7f2e8 0%, #f3efe6 52%, #eee4d4 100%)",
        "grad_dark": nacre(4)[0],
        "grad_light": nacre(4)[1],
        "fns": WORK_FNS,
        "skip": 0.10,
        "scale": (2.10, 3.05),
        "rot": 14,
        "cols": 5,
        "rows": 11,
        "seed": 57,
    },
    "space": {
        "title": "Космонавтика",
        "title_en": "Space",
        "bg_dark": "radial-gradient(120% 90% at 20% 0%, #141c2c 0%, #0a0e14 50%, #10141e 100%)",
        "bg_light": "radial-gradient(120% 90% at 20% 0%, #eef3fa 0%, #eef2f6 52%, #e2e8f0 100%)",
        "grad_dark": nacre(6)[0],
        "grad_light": nacre(6)[1],
        "fns": SPACE_FNS,
        "skip": 0.06,
        "scale": (1.75, 2.55),
        "rot": 8,
        "cols": 5,
        "rows": 12,
        "seed": 73,
        "heroes": True,
    },
}


def scatter(rng: random.Random, spec: dict) -> list[tuple]:
    cols, rows = spec["cols"], spec["rows"]
    gx, gy = W / cols, H / rows
    fns = spec["fns"]
    groups = spec.get("groups")
    dense = spec.get("dense", False)
    even = spec.get("even", False)
    items = []
    k = 0
    for r in range(rows):
        for col in range(cols):
            if rng.random() < spec["skip"]:
                continue
            if even:
                jitter = 0.12 if dense else 0.10
                stagger = 0.06
            else:
                jitter = 0.38 if dense else 0.30
                stagger = 0.18
            x = (col + 0.5) * gx + rng.uniform(-gx * jitter, gx * jitter)
            y = (r + 0.5) * gy + rng.uniform(-gy * jitter, gy * jitter)
            if r % 2:
                x += gx * stagger
            rot = rng.uniform(-spec["rot"], spec["rot"])
            if even:
                sc = rng.uniform(*spec["scale"])
                op = rng.uniform(0.52, 0.94) if dense else rng.uniform(0.58, 1.0)
            elif dense:
                sc = rng.uniform(1.35, 1.95) if rng.random() < 0.14 else rng.uniform(*spec["scale"])
                op = rng.uniform(0.40, 0.96)
            else:
                sc = rng.uniform(*spec["scale"])
                if spec.get("heroes") and rng.random() < 0.18:
                    sc *= 1.32
                elif rng.random() < 0.08:
                    sc *= 1.25
                op = rng.uniform(0.55, 1.0)
            if groups:
                gi = min(col * len(groups) // cols, len(groups) - 1)
                pool = groups[gi]
                heads = [fn for fn in pool if fn.__name__.startswith("phd_")]
                body = [fn for fn in pool if not fn.__name__.startswith("phd_")]
                first_col = gi * cols // len(groups)
                if heads and r == 0 and col == first_col:
                    fn = heads[0]
                else:
                    fn = body[(r * 3 + col) % len(body)]
            else:
                fn = rng.choice(fns)
            items.append((x, y, rot, sc, fn, op))
            k += 1
    return items


def paint_defs(gid: str, stops: list[str]) -> str:
    n = max(len(stops) - 1, 1)
    stop_xml = []
    for i, col in enumerate(stops):
        stop_xml.append(f'<stop offset="{i/n:.3f}" stop-color="{col}"/>')
    return (
        "<defs>"
        f'<linearGradient id="{gid}" gradientUnits="userSpaceOnUse" '
        f'x1="0" y1="0" x2="{W}" y2="{H}">'
        + "".join(stop_xml)
        + "</linearGradient>"
        "</defs>"
    )


def svg_for(name: str, mode: str = "dark", spec: dict | None = None) -> str:
    global S
    spec = spec or THEMES[name]
    gid = f"ink-{name}-{mode}"
    S = f"url(#{gid})"
    rng = random.Random(spec["seed"])
    stops = spec["grad_dark" if mode == "dark" else "grad_light"]
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" '
        f'preserveAspectRatio="xMidYMid slice" fill="none" aria-hidden="true">',
        paint_defs(gid, stops),
    ]
    for x, y, rot, sc, fn, op in scatter(rng, spec):
        parts.append(
            f'<g opacity="{op:.2f}" transform="translate({x:.1f} {y:.1f}) '
            f'rotate({rot:.1f}) scale({sc:.3f})">{fn()}</g>'
        )
    parts.append("</svg>")
    return "\n".join(parts)


def write_svgs() -> dict[tuple[str, str], str]:
    OUT.mkdir(parents=True, exist_ok=True)
    out = {}
    for name in THEMES:
        dark = svg_for(name, "dark")
        light = svg_for(name, "light")
        (OUT / f"{name}.svg").write_text(dark, encoding="utf-8")
        (OUT / f"{name}-light.svg").write_text(light, encoding="utf-8")
        out[(name, "dark")] = dark
        out[(name, "light")] = light
        print("wrote", OUT / f"{name}.svg")
    return out


def gallery_html(svgs: dict[tuple[str, str], str]) -> str:
    cards = []
    for name, spec in THEMES.items():
        cards.append(f"""
<section class="theme">
  <header>
    <h2>{spec['title']}</h2>
    <p>{spec['title_en']} · прозрачный SVG, цвет переливается по полю</p>
  </header>
  <div class="pair">
    <figure class="phone dark" style="background:{spec['bg_dark']}">
      {svgs[(name, "dark")]}
      <div class="bubbles">
        <div class="in">Доброе утро</div>
        <div class="out">Тема сменилась — дудли на месте</div>
      </div>
      <figcaption>тёмная</figcaption>
    </figure>
    <figure class="phone light" style="background:{spec['bg_light']}">
      {svgs[(name, "light")]}
      <div class="bubbles">
        <div class="in">Доброе утро</div>
        <div class="out">Тема сменилась — дудли на месте</div>
      </div>
      <figcaption>светлая</figcaption>
    </figure>
  </div>
</section>""")
    inner = "\n".join(cards)
    return f"""<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>Обои как в Telegram</title>
<link rel="preconnect" href="https://fonts.googleapis.com"/>
<link href="https://fonts.googleapis.com/css2?family=Kalam:wght@400;700&family=Manrope:wght@400;600;800&display=swap" rel="stylesheet"/>
<style>
  :root {{ --ink:#f4f0e8; --muted:#9a948a; --bg:#0b0a08; }}
  * {{ box-sizing: border-box; }}
  html, body {{ margin:0; background:
    radial-gradient(90% 60% at 50% 0%, #1b1712 0%, #0b0a08 62%);
    color: var(--ink); font-family: Manrope, sans-serif; }}
  main {{ max-width: 980px; margin: 0 auto; padding: 36px 20px 80px; }}
  h1 {{ font-size: 28px; font-weight: 800; letter-spacing: -.03em; margin: 0 0 8px; }}
  .lead {{ color: var(--muted); max-width: 46rem; line-height: 1.55; margin: 0 0 28px; }}
  .lead b {{ color: var(--ink); font-weight: 600; }}
  .theme {{ margin: 0 0 42px; }}
  .theme header h2 {{ margin: 0; font-size: 18px; }}
  .theme header p {{ margin: 4px 0 14px; color: var(--muted); font-size: 13px; }}
  .pair {{ display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }}
  .phone {{
    position: relative; height: 560px; border-radius: 28px; overflow: hidden;
    box-shadow: 0 0 0 1px rgba(255,255,255,.08), 0 24px 50px -28px #000;
  }}
  .phone::after {{
    content: ""; position: absolute; inset: 0; pointer-events: none; z-index: 2;
    background:
      radial-gradient(70% 46% at 28% 12%, rgba(255,255,255,.16), transparent 58%),
      linear-gradient(118deg, transparent 18%, rgba(255,255,255,.07) 42%, transparent 68%);
    mix-blend-mode: soft-light;
  }}
  .phone.light::after {{
    background:
      radial-gradient(70% 46% at 28% 12%, rgba(255,255,255,.5), transparent 58%),
      linear-gradient(118deg, transparent 18%, rgba(255,255,255,.22) 42%, transparent 68%);
  }}
  .phone svg {{ position: absolute; inset: 0; width: 100%; height: 100%;
    pointer-events: none; }}
  .phone.dark svg {{ mix-blend-mode: plus-lighter; opacity: .82; }}
  .phone.light svg {{ mix-blend-mode: multiply; opacity: .7; }}
  .bubbles {{ position: relative; z-index: 3; padding: 72px 16px 0; display: flex;
    flex-direction: column; gap: 10px; }}
  .bubbles .in, .bubbles .out {{
    max-width: 78%; padding: 10px 14px; border-radius: 16px; font-size: 13px;
    line-height: 1.35;
  }}
  .in {{ align-self: flex-start; background: rgba(40,40,38,.82); color: #eee; }}
  .out {{ align-self: flex-end; background: #3d7ee8; color: #fff; }}
  .light .in {{ background: rgba(255,255,255,.86); color: #1c1a16;
    box-shadow: 0 1px 0 rgba(0,0,0,.06); }}
  .light .out {{ background: #3d7ee8; }}
  figcaption {{ position: absolute; left: 14px; bottom: 12px; z-index: 3;
    font-size: 11px; letter-spacing: .12em; text-transform: uppercase;
    opacity: .55; }}
  .light figcaption {{ color: #1c1a16; }}
  @media (max-width: 720px) {{
    .pair {{ grid-template-columns: 1fr; }}
    .phone {{ height: 520px; }}
  }}
</style>
</head>
<body>
<main>
  <h1>Обои как в Telegram</h1>
  <p class="lead">
    Тот же приём, что в чатах Telegram: <b>SVG-дудли на прозрачном фоне</b>,
    цвет перламутровый — мята, циан, сирень, золото. Математика и физика
    как тетрадный черновик: мелко, плотно, без зачёркиваний. Фон темы
    меняется, рисунок остаётся.
  </p>
  {inner}
</main>
</body>
</html>
"""


ROOT = Path(__file__).resolve().parents[1]
FONT_DIR = ROOT / "scripts" / "wallpaper-fonts"
ASSET_DIR = ROOT / "app" / "assets" / "wallpapers" / "doodles"

# Widescreen packs. Mobile 720×1280 JPGs are already checked in.
PACKS = {
    "fhd": {
        "size": (1920, 1080),
        "math": {"cols": 28, "rows": 16, "skip": 0.015, "scale": (0.78, 1.28), "rot": 16},
        "physics": {"cols": 28, "rows": 16, "skip": 0.015, "scale": (0.78, 1.28), "rot": 16},
        "code": {"cols": 14, "rows": 9, "skip": 0.06, "scale": (1.55, 2.45), "rot": 14},
        "date": {"cols": 14, "rows": 9, "skip": 0.05, "scale": (1.55, 2.45), "rot": 18},
        "work": {"cols": 14, "rows": 9, "skip": 0.06, "scale": (1.55, 2.35), "rot": 12},
        "space": {"cols": 14, "rows": 10, "skip": 0.04, "scale": (1.35, 2.05), "rot": 8},
    },
    "2k": {
        "size": (2560, 1440),
        "math": {"cols": 36, "rows": 20, "skip": 0.015, "scale": (0.82, 1.32), "rot": 16},
        "physics": {"cols": 36, "rows": 20, "skip": 0.015, "scale": (0.82, 1.32), "rot": 16},
        "code": {"cols": 18, "rows": 12, "skip": 0.06, "scale": (1.60, 2.55), "rot": 14},
        "date": {"cols": 18, "rows": 12, "skip": 0.05, "scale": (1.60, 2.55), "rot": 18},
        "work": {"cols": 18, "rows": 12, "skip": 0.06, "scale": (1.60, 2.45), "rot": 12},
        "space": {"cols": 18, "rows": 13, "skip": 0.04, "scale": (1.40, 2.15), "rot": 8},
    },
}


def _font_css() -> str:
    import base64

    regular = base64.b64encode((FONT_DIR / "Kalam-Regular.ttf").read_bytes()).decode()
    bold = base64.b64encode((FONT_DIR / "Kalam-Bold.ttf").read_bytes()).decode()
    return (
        "@font-face{font-family:'Kalam';font-weight:400;"
        f"src:url(data:font/ttf;base64,{regular}) format('truetype');}}"
        "@font-face{font-family:'Kalam';font-weight:700;"
        f"src:url(data:font/ttf;base64,{bold}) format('truetype');}}"
    )


def html_page(name: str, mode: str, svg: str, w: int, h: int) -> str:
    spec = THEMES[name]
    bg = spec["bg_dark" if mode == "dark" else "bg_light"]
    blend = "plus-lighter" if mode == "dark" else "multiply"
    op = "0.82" if mode == "dark" else "0.70"
    if mode == "dark":
        sheen = (
            "radial-gradient(70% 46% at 28% 12%, rgba(255,255,255,.16), transparent 58%),"
            "linear-gradient(118deg, transparent 18%, rgba(255,255,255,.07) 42%, transparent 68%)"
        )
    else:
        sheen = (
            "radial-gradient(70% 46% at 28% 12%, rgba(255,255,255,.5), transparent 58%),"
            "linear-gradient(118deg, transparent 18%, rgba(255,255,255,.22) 42%, transparent 68%)"
        )
    return f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"/>
<style>
{_font_css()}
html,body{{margin:0;padding:0;width:{w}px;height:{h}px;overflow:hidden;background:{bg};}}
svg{{position:absolute;inset:0;width:100%;height:100%;mix-blend-mode:{blend};opacity:{op};pointer-events:none;}}
.sheen{{position:absolute;inset:0;pointer-events:none;mix-blend-mode:soft-light;background:{sheen};}}
</style></head>
<body>
{svg}
<div class="sheen"></div>
</body></html>
"""


def screenshot(html_path: Path, png_path: Path, w: int, h: int) -> None:
    cmd = [
        "google-chrome-stable",
        "--headless=new",
        "--disable-gpu",
        "--hide-scrollbars",
        "--no-first-run",
        "--no-default-browser-check",
        "--force-device-scale-factor=1",
        f"--window-size={w},{h}",
        f"--screenshot={png_path}",
        html_path.resolve().as_uri(),
    ]
    subprocess.run(cmd, check=True, capture_output=True)


def png_to_jpg(png_path: Path, jpg_path: Path) -> None:
    subprocess.run(
        [
            "magick",
            str(png_path),
            "-strip",
            "-sampling-factor",
            "4:2:0",
            "-quality",
            "82",
            str(jpg_path),
        ],
        check=True,
    )


def render_pack(pack: str, themes: list[str] | None = None) -> None:
    import tempfile

    global W, H
    cfg = PACKS[pack]
    w, h = cfg["size"]
    W, H = w, h
    names = themes or list(THEMES)
    out_dir = ASSET_DIR / pack
    out_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=f"privet-wall-{pack}-") as tmp:
        tmp_path = Path(tmp)
        for name in names:
            spec = dict(THEMES[name])
            spec.update(cfg[name])
            for mode in ("dark", "light"):
                svg = svg_for(name, mode, spec)
                html = html_page(name, mode, svg, w, h)
                html_file = tmp_path / f"{name}-{mode}.html"
                png_file = tmp_path / f"{name}-{mode}.png"
                jpg_file = out_dir / f"{name}-{mode}.jpg"
                html_file.write_text(html, encoding="utf-8")
                screenshot(html_file, png_file, w, h)
                # Chrome sometimes writes a 2× capture; force the pack size.
                subprocess.run(
                    ["magick", str(png_file), "-resize", f"{w}x{h}!", str(png_file)],
                    check=True,
                )
                png_to_jpg(png_file, jpg_file)
                print("wrote", jpg_file, jpg_file.stat().st_size)


def main() -> None:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument(
        "packs",
        nargs="*",
        default=list(PACKS),
        help="fhd, 2k (default: both)",
    )
    parser.add_argument(
        "--theme",
        action="append",
        dest="themes",
        help="render only this theme (repeatable)",
    )
    args = parser.parse_args()
    if args.themes:
        unknown = [name for name in args.themes if name not in THEMES]
        if unknown:
            raise SystemExit(f"unknown theme {', '.join(unknown)}")
    for pack in args.packs:
        if pack not in PACKS:
            raise SystemExit(f"unknown pack {pack}")
        render_pack(pack, args.themes)


if __name__ == "__main__":
    main()
