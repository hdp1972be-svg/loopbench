#!/usr/bin/env bash
# txt2png.sh — Convert a plain text file to PNG (preformatted, A4, line-wrapped)
# Usage: txt2png.sh <file.txt> [dpi]
#
# Dependencies: pdflatex, pdftoppm (texlive + poppler-utils)

set -Eeuo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <file.txt> [dpi]" >&2
    exit 1
fi

INPUT="$1"
DPI="${2:-150}"

if [[ ! -f "$INPUT" ]]; then
    echo "ERROR: File not found: $INPUT" >&2
    exit 1
fi

BASE="$(basename "$INPUT" .txt)"
BASEDIR="$(cd "$(dirname "$INPUT")" && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "$INPUT" "$WORK/input.txt"

# Sanitize glyphs the LaTeX typewriter font lacks (e.g. °C -> degC).
sed -e 's/°C/degC/g' "$WORK/input.txt" > "$WORK/input_clean.txt"

cat > "$WORK/convert.tex" <<'TEX'
\documentclass[11pt]{article}
\usepackage[a4paper,margin=1in]{geometry}
\usepackage{listings}
\usepackage{xcolor}
\usepackage[utf8]{inputenc}
\lstset{
  basicstyle=\ttfamily\scriptsize,
  breaklines=true,
  breakatwhitespace=true,
  columns=flexible,
  keepspaces=true,
  showstringspaces=false,
  frame=single,
  backgroundcolor=\color{black!5},
  extendedchars=true,
}
\pagestyle{empty}
\begin{document}
\lstinputlisting{input_clean.txt}
\end{document}
TEX

cd "$WORK"

echo "Running pdflatex..."
pdflatex -interaction=nonstopmode convert.tex > pdflatex.log 2>&1 || {
    echo "ERROR: pdflatex failed:" >&2
    cat pdflatex.log >&2
    exit 1
}

if [[ ! -f convert.pdf ]]; then
    echo "ERROR: pdflatex did not produce convert.pdf" >&2
    cat pdflatex.log >&2
    exit 1
fi

echo "Rendering PDF to PNG at ${DPI} DPI..."
pdftoppm -png -r "$DPI" convert.pdf "$BASE" >/dev/null 2>&1 || {
    echo "ERROR: pdftoppm failed" >&2
    exit 1
}

shopt -s nullglob
pngs=("$BASE"-*.png)
shopt -u nullglob

if [[ ${#pngs[@]} -eq 0 ]]; then
    echo "ERROR: No PNG output produced" >&2
    exit 1
fi

cp "${pngs[@]}" "$BASEDIR/"

echo "Done. PNGs written to: $BASEDIR/${BASE}-*.png"
ls -1 "$BASEDIR/${BASE}"-*.png
