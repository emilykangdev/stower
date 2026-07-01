#!/usr/bin/env python3
"""Append one <item> to the Sparkle appcast for a new StowerMac release.

Invoked by the "Sign update and amend appcast" step in
``.github/workflows/release.yml``. All inputs arrive via environment variables
so the workflow can pass GitHub expression values through ``env:`` (avoiding
template injection into a shell heredoc) and so the logic is independently
lintable/testable instead of living inline in the YAML.

Required environment variables:
  APPCAST_PATH      path to the appcast.xml to amend in place
  VERSION           marketing version (CFBundleShortVersionString)
  BUILD             build number (CFBundleVersion / sparkle:version)
  PUB_DATE          RFC-822 publication date
  NOTES_URL         release-notes URL (sparkle:releaseNotesLink)
  ASSET_URL         enclosure download URL
  FILE_SIZE         enclosure length in bytes
  ED_SIGNATURE      base64 EdDSA signature (sparkle:edSignature)
  ROLLOUT_INTERVAL  sparkle:phasedRolloutInterval in seconds

The new item is inserted immediately before the closing </channel> tag. The
feed must already contain </channel>; otherwise this exits non-zero so the
workflow fails loudly rather than producing a malformed feed.
"""

import os
import sys

p = os.environ["APPCAST_PATH"]
v = os.environ["VERSION"]
b = os.environ["BUILD"]
d = os.environ["PUB_DATE"]
n = os.environ["NOTES_URL"]
a = os.environ["ASSET_URL"]
z = os.environ["FILE_SIZE"]
e = os.environ["ED_SIGNATURE"]
r = os.environ["ROLLOUT_INTERVAL"]

item = (
    "    <item>\n"
    "      <title>Stower " + v + "</title>\n"
    "      <pubDate>" + d + "</pubDate>\n"
    "      <sparkle:releaseNotesLink>" + n + "</sparkle:releaseNotesLink>\n"
    "      <sparkle:version>" + b + "</sparkle:version>\n"
    "      <sparkle:shortVersionString>" + v + "</sparkle:shortVersionString>\n"
    "      <sparkle:phasedRolloutInterval>" + r + "</sparkle:phasedRolloutInterval>\n"
    "      <enclosure\n"
    '        url="' + a + '"\n'
    '        length="' + z + '"\n'
    '        type="application/octet-stream"\n'
    '        sparkle:edSignature="' + e + '"\n'
    "      />\n"
    "    </item>"
)

with open(p) as f:
    content = f.read()

tag = "</channel>"
if tag not in content:
    print("ERROR: </channel> not found", file=sys.stderr)
    sys.exit(1)

updated = content.replace(tag, item + "\n  " + tag)
with open(p, "w") as f:
    f.write(updated)
print("Appcast amended.")
