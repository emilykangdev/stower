# Release notes

One authored Markdown file per release, named exactly `<VERSION>.md` where
`<VERSION>` is the marketing version in the tag (`messages-v<VERSION>`). For the
tag `messages-v0.2.0`, the file is `Docs/release-notes/0.2.0.md`.

## How the pipeline uses this file

`release.yml` reads `Docs/release-notes/<VERSION>.md` and publishes it to **two**
surfaces, so both show identical content:

1. **GitHub Release body** — GitHub renders the Markdown natively
   (`gh release create --notes-file`).
2. **Sparkle in-app "what's new"** — `Scripts/release/render_notes_html.py`
   renders the same Markdown to `messages/notes/<VERSION>.html` on `gh-pages`;
   Sparkle loads it via `<sparkle:releaseNotesLink>`.

A tag push with a missing or empty notes file **fails the release loudly**
(the "Verify authored release notes present" step runs before archive/notarize),
so a release can never ship empty notes.

## Authoring

Write the notes **before** you tag. Keep them user-facing — real users read them
in the update prompt. Supported Markdown subset (see `render_notes_html.py`):

- ATX headings (`#`..`######`)
- Unordered lists (`-` or `*`)
- Paragraphs
- Inline `**bold**`, `` `code` ``, and `[text](url)`

Nested lists, ordered lists, tables, and blockquotes are **not** rendered — keep
to the subset above.
