#!/usr/bin/env python3
"""Render an authored release-notes Markdown file to the Sparkle notes HTML page.

Invoked by the "Sign update and amend appcast" step in
``.github/workflows/release.yml``. The same ``Docs/release-notes/<VERSION>.md``
file feeds two consumers so both render identical content:
  1. the GitHub Release body — GitHub renders the Markdown natively
     (``gh release create --notes-file``), and
  2. the Sparkle in-app "what's new" page — Sparkle loads the URL in
     ``<sparkle:releaseNotesLink>``, which points at the HTML this script writes.

All inputs arrive via environment variables so the workflow can pass GitHub
expression values through ``env:`` (avoiding template injection into a shell
heredoc) and so the logic is independently testable instead of living inline in
the YAML.

Required environment variables:
  NOTES_MD    path to the authored Markdown notes for this version
  NOTES_HTML  path to write the rendered HTML page to
  VERSION     marketing version (used in <title> and the page heading)

Supported Markdown subset (what release notes actually use): ATX headings
(``#``..``######``), unordered lists (``-``/``*``), paragraphs, and the inline
spans ``**bold**``, `` `code` ``, and ``[text](url)``. Nested lists, ordered
lists, tables, and blockquotes are intentionally NOT supported — keep notes to
the subset above. Everything is HTML-escaped before inline markup is applied.

Exits non-zero (fails the release loudly) if NOTES_MD is missing or empty, so a
release can never publish an empty "what's new" page.
"""

import html
import os
import re
import sys

notes_md_path = os.environ["NOTES_MD"]
notes_html_path = os.environ["NOTES_HTML"]
version = os.environ["VERSION"]

if not os.path.isfile(notes_md_path):
    print("ERROR: release notes not found at " + notes_md_path, file=sys.stderr)
    print("Author Docs/release-notes/<VERSION>.md before tagging this release.", file=sys.stderr)
    sys.exit(1)

with open(notes_md_path) as f:
    markdown = f.read()

if not markdown.strip():
    print("ERROR: release notes at " + notes_md_path + " are empty.", file=sys.stderr)
    sys.exit(1)


def render_inline(text):
    """HTML-escape text, then apply the inline Markdown spans we support."""
    text = html.escape(text, quote=False)
    text = re.sub(r"`([^`]+)`", lambda m: "<code>" + m.group(1) + "</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", lambda m: "<strong>" + m.group(1) + "</strong>", text)
    text = re.sub(
        r"\[([^\]]+)\]\(([^)]+)\)",
        lambda m: '<a href="' + m.group(2) + '">' + m.group(1) + "</a>",
        text,
    )
    return text


def render_blocks(md):
    """Convert the supported Markdown block structures to HTML."""
    lines = md.split("\n")
    out = []
    para = []

    def flush_para():
        if para:
            out.append("<p>" + " ".join(render_inline(line) for line in para) + "</p>")
            para.clear()

    i = 0
    while i < len(lines):
        stripped = lines[i].strip()
        if not stripped:
            flush_para()
            i += 1
            continue
        heading = re.match(r"^(#{1,6})\s+(.*)$", stripped)
        if heading:
            flush_para()
            level = len(heading.group(1))
            out.append("<h{0}>{1}</h{0}>".format(level, render_inline(heading.group(2))))
            i += 1
            continue
        if re.match(r"^[-*]\s+", stripped):
            flush_para()
            items = []
            current = None
            # A blank line, a heading, or EOF ends the list. A line that starts a
            # new bullet opens a new item; any other non-blank line is a lazy
            # continuation (a soft-wrapped bullet) folded into the current item.
            while i < len(lines):
                s = lines[i].strip()
                if not s or re.match(r"^#{1,6}\s+", s):
                    break
                if re.match(r"^[-*]\s+", s):
                    if current is not None:
                        items.append(current)
                    current = re.sub(r"^[-*]\s+", "", s)
                else:
                    if current is None:
                        break
                    current += " " + s
                i += 1
            if current is not None:
                items.append(current)
            rendered = "\n".join("  <li>" + render_inline(it) + "</li>" for it in items)
            out.append("<ul>\n" + rendered + "\n</ul>")
            continue
        para.append(stripped)
        i += 1
    flush_para()
    return "\n".join(out)


body = render_blocks(markdown)
escaped_version = html.escape(version, quote=True)

# Minimal, intentional styling: system font, readable measure, dark-mode aware.
# This page renders inside Sparkle's WKWebView, so it must stand on its own with
# no external stylesheet or network dependency.
page = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Stower {version}</title>
<style>
  :root {{ color-scheme: light dark; }}
  body {{
    font: 15px/1.6 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
    max-width: 44rem;
    margin: 2.5rem auto;
    padding: 0 1.5rem;
    color: #1d1d1f;
    background: #ffffff;
  }}
  h1, h2, h3, h4, h5, h6 {{ line-height: 1.25; margin: 1.6em 0 0.5em; }}
  h1 {{ font-size: 1.5rem; }}
  h2 {{ font-size: 1.2rem; }}
  h3 {{ font-size: 1.05rem; }}
  ul {{ padding-left: 1.4rem; }}
  li {{ margin: 0.25em 0; }}
  code {{
    font: 0.9em ui-monospace, SFMono-Regular, Menlo, monospace;
    background: rgba(127, 127, 127, 0.15);
    padding: 0.1em 0.35em;
    border-radius: 4px;
  }}
  a {{ color: #0066cc; }}
  @media (prefers-color-scheme: dark) {{
    body {{ color: #f5f5f7; background: #1d1d1f; }}
    a {{ color: #6ab0ff; }}
  }}
</style>
</head>
<body>
{body}
</body>
</html>
""".format(version=escaped_version, body=body)

with open(notes_html_path, "w") as f:
    f.write(page)
print("Rendered release notes HTML to " + notes_html_path)
