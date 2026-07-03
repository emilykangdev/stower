#!/usr/bin/env python3
"""Regenerate the Stower demo Messages database.

Writes a synthetic, send-free `chat.db` to the app-support DemoData folder that
Stower reads when demoing the relationship-debt board. It contains 15 threads
that land in "Your turn" (Neglected: counterpart sent last, expects a reply) and
15 that land in "Maybe follow up" (Ghosted: you sent last, they went quiet).

The classifier gates it reads (see StowerNoReplyPolicy / StowerGhostedPolicy /
StowerConversationStateExtractor):
  - 1:1 chat            -> chat.style = 45 (directChatStyle)
  - reciprocity >= 1    -> each thread has >=1 inbound and >=1 outbound act
                           inside the 60-day reciprocity window
  - unanswered >= 3d    -> last message is dated >3 days ago
  - read window 180d    -> every message is dated <180 days ago
  - expects-reply       -> the last message reads as a genuine ask so the
                           on-device model judges it should-respond. Many are
                           LEADING asks with no question mark ("lmk what works",
                           "send me your dates") to show the model reads intent,
                           not punctuation.

"Maybe follow up" threads end on YOUR outreach the other side hasn't answered,
and are dated OLDER than the "Your turn" threads so the board reads "you reached
out, they haven't responded in a while".

All data is fake (555-01xx numbers, invented text) per the repo's rule against
real Messages data in fixtures. Dates are anchored to "now" at run time so the
board always shows fresh, in-window threads.

Usage:  python3 Scripts/generate-demo-db.py
"""

import os
import sqlite3
import time
from datetime import datetime, timedelta

# Apple's Core Data / Messages reference date: 2001-01-01 00:00:00 UTC.
APPLE_EPOCH_UNIX = 978307200
# chat.style value for a one-to-one (non-group) conversation.
DIRECT_CHAT_STYLE = 45

DEMO_DB_PATH = os.path.expanduser(
    "~/Library/Application Support/Stower/DemoData/chat.db"
)

# Each thread is (oldest -> newest) list of (is_from_me, text).
# "Your turn" threads MUST end inbound (is_from_me=0) on a message that expects a
# reply — many are LEADING asks with no question mark.
YOUR_TURN = [
    [(0, "hey! it's been way too long, we should catch up"),
     (1, "yes!! this week is insane but next week im free"),
     (0, "no worries, keep me posted"),
     (0, "still on for coffee this weekend, lmk what time works")],
    [(1, "sent over the deck, let me know what you think"),
     (0, "looks great! one question on slide 4"),
     (1, "sure, what's up"),
     (0, "did you finish the revisions? the deadline is friday")],
    [(0, "loved the photos from the trip"),
     (1, "thank you!! it was so much fun"),
     (0, "we should plan another one"),
     (0, "take a look at the venue options I sent whenever you get a sec")],
    [(1, "happy birthday!! hope it's a good one"),
     (0, "thank you so much!"),
     (0, "we're doing a little dinner next month, would love for you to come")],
    [(0, "you around this weekend?"),
     (1, "should be, why?"),
     (0, "wanted to swing by and grab that book, tell me what time is good")],
    [(1, "great meeting you at the conference"),
     (0, "likewise! let's stay in touch"),
     (0, "still hoping you can intro me to your PM friend when you get a moment")],
    [(0, "the landlord finally emailed back"),
     (1, "oh nice, what did they say"),
     (0, "long story, call me when you get a sec?")],
    [(1, "thanks for covering my shift!"),
     (0, "of course, anytime"),
     (0, "any chance you could do the same for me next thursday?")],
    [(0, "did the package ever show up?"),
     (1, "not yet, so annoying"),
     (0, "ugh, lmk if you want me to file the claim")],
    [(1, "how'd the interview go??"),
     (0, "i think good! nervous though"),
     (0, "would love to put you down as a reference if that's ok")],
    [(0, "recipe was a hit, everyone loved it"),
     (1, "yay so glad!!"),
     (0, "send me the dessert one too when you get a chance")],
    [(1, "we still on for the gym monday"),
     (0, "yep 7am works"),
     (0, "actually can we push to 8?")],
    [(0, "car's making that noise again"),
     (1, "the rattling one?"),
     (0, "yeah, send me the name of that mechanic near you")],
    [(1, "loved your talk today"),
     (0, "aw thank you, that means a lot"),
     (0, "would you mind sharing the slides with your team?")],
    [(0, "flights for the trip are getting expensive"),
     (1, "yeah we should book soon"),
     (0, "send me your dates so I can lock it in")],
]

# "Maybe follow up" threads MUST end outbound (is_from_me=1): YOUR outreach the
# other side has left hanging. Many are leading asks with no question mark.
MAYBE_FOLLOW_UP = [
    [(0, "hey, are you around this weekend?"),
     (1, "yeah, what's up"),
     (0, "was thinking dinner saturday"),
     (1, "let me know if saturday still works for you")],
    [(0, "hope the move went smoothly!"),
     (1, "it did, thank you! still unpacking boxes lol"),
     (0, "haha classic"),
     (1, "we should do a housewarming, you'd come right?")],
    [(1, "did you ever hear back from the recruiter?"),
     (0, "not yet, kind of worried"),
     (1, "hang in there, i can intro you to my contact there if you want")],
    [(0, "thanks again for dinner last week"),
     (1, "anytime! we should do it more often"),
     (1, "let's make it a regular thing, you free the 14th?")],
    [(1, "sent you the invoice this morning"),
     (0, "got it, thanks"),
     (1, "just checking you were able to process it ok")],
    [(0, "the show was incredible"),
     (1, "right?? best one this year"),
     (1, "we should grab tickets for the next tour together")],
    [(1, "how's the new place treating you"),
     (0, "loving it honestly"),
     (1, "let's christen it with a dinner party, thinking next month")],
    [(0, "quick q about the group gift"),
     (1, "yeah go for it"),
     (1, "can you venmo me your share when you get a chance?")],
    [(1, "great catching up today"),
     (0, "same! felt like no time passed"),
     (1, "let's not wait a year again, brunch in two weeks?")],
    [(0, "did the client sign off?"),
     (1, "almost, one more round of edits"),
     (1, "can you take a pass at the intro before eod?")],
    [(1, "happy anniversary you two!!"),
     (0, "thank you!! can't believe it's been 5 years"),
     (1, "we have to celebrate, dinner's on us whenever you're free")],
    [(0, "loved the book you recommended"),
     (1, "right?? the ending destroyed me"),
     (1, "we should do a little two-person book club")],
    [(1, "you doing ok? been thinking about you"),
     (0, "hanging in there, thanks for checking in"),
     (1, "i'm bringing you dinner this week, just tell me a day")],
    [(0, "the hike almost killed me lol"),
     (1, "haha you survived though!"),
     (1, "up for an easier one next weekend? maybe the coast")],
    [(1, "congrats on the promotion!!"),
     (0, "thank you!! still in shock"),
     (1, "this calls for drinks, are you free friday?")],
]


def to_apple_ns(dt):
    """Datetime -> Apple nanoseconds-since-2001 (what Messages stores)."""
    return int((dt.timestamp() - APPLE_EPOCH_UNIX) * 1_000_000_000)


def create_schema(cur):
    cur.executescript(
        """
        DROP TABLE IF EXISTS message;
        DROP TABLE IF EXISTS handle;
        DROP TABLE IF EXISTS chat;
        DROP TABLE IF EXISTS chat_message_join;
        DROP TABLE IF EXISTS chat_handle_join;
        CREATE TABLE message (
          guid TEXT NOT NULL,
          text TEXT,
          attributedBody BLOB,
          date INTEGER NOT NULL,
          is_from_me INTEGER NOT NULL,
          handle_id INTEGER NOT NULL,
          associated_message_type INTEGER NOT NULL,
          associated_message_guid TEXT,
          item_type INTEGER NOT NULL,
          cache_has_attachments INTEGER NOT NULL,
          balloon_bundle_id TEXT
        );
        CREATE TABLE handle (id TEXT NOT NULL);
        CREATE TABLE chat (
          guid TEXT,
          chat_identifier TEXT NOT NULL,
          display_name TEXT,
          style INTEGER NOT NULL
        );
        CREATE TABLE chat_message_join (
          chat_id INTEGER NOT NULL,
          message_id INTEGER NOT NULL
        );
        CREATE TABLE chat_handle_join (
          chat_id INTEGER NOT NULL,
          handle_id INTEGER NOT NULL
        );
        """
    )


def insert_thread(cur, chat_index, handle_rowid, phone, thread, last_msg_days_ago):
    """Insert one 1:1 thread. Last message is `last_msg_days_ago` days old.

    Earlier messages are spaced one day apart before the last one, keeping the
    whole thread inside the 60-day reciprocity window.
    """
    cur.execute("INSERT INTO handle (rowid, id) VALUES (?, ?)", (handle_rowid, phone))
    cur.execute(
        "INSERT INTO chat (rowid, guid, chat_identifier, display_name, style) "
        "VALUES (?, ?, ?, ?, ?)",
        (handle_rowid, f"demo-chat-{chat_index}", phone, "", DIRECT_CHAT_STYLE),
    )
    cur.execute(
        "INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (?, ?)",
        (handle_rowid, handle_rowid),
    )

    count = len(thread)
    now = datetime.now()
    for msg_index, (is_from_me, text) in enumerate(thread):
        # Oldest first: message i is (count-1-i) days before the last one.
        days_before_last = (count - 1 - msg_index)
        sent_at = now - timedelta(days=last_msg_days_ago + days_before_last, hours=3)
        cur.execute(
            "INSERT INTO message "
            "(guid, text, attributedBody, date, is_from_me, handle_id, "
            " associated_message_type, associated_message_guid, item_type, "
            " cache_has_attachments, balloon_bundle_id) "
            "VALUES (?, ?, NULL, ?, ?, ?, 0, NULL, 0, 0, NULL)",
            (
                f"demo-{chat_index}-{msg_index}",
                text,
                to_apple_ns(sent_at),
                is_from_me,
                0 if is_from_me else handle_rowid,
            ),
        )
        message_rowid = cur.lastrowid
        cur.execute(
            "INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)",
            (handle_rowid, message_rowid),
        )


# "Your turn" reads fresh (a few days), "Maybe follow up" reads stale ("a while")
# — both comfortably >3 days (qualifies) and <60 days (reciprocity window).
YOUR_TURN_FIRST_AGE_DAYS = 4
MAYBE_FOLLOW_UP_FIRST_AGE_DAYS = 12


def main():
    os.makedirs(os.path.dirname(DEMO_DB_PATH), exist_ok=True)
    if os.path.exists(DEMO_DB_PATH):
        os.remove(DEMO_DB_PATH)
    conn = sqlite3.connect(DEMO_DB_PATH)
    cur = conn.cursor()
    create_schema(cur)

    threads = YOUR_TURN + MAYBE_FOLLOW_UP
    for i, thread in enumerate(threads):
        phone = f"+1415555{100 + i:04d}"
        if i < len(YOUR_TURN):
            last_msg_days_ago = YOUR_TURN_FIRST_AGE_DAYS + i
        else:
            last_msg_days_ago = MAYBE_FOLLOW_UP_FIRST_AGE_DAYS + (i - len(YOUR_TURN))
        insert_thread(cur, i, i + 1, phone, thread, last_msg_days_ago)

    conn.commit()
    conn.close()
    print(
        f"Wrote {len(threads)} demo threads "
        f"({len(YOUR_TURN)} Your turn + {len(MAYBE_FOLLOW_UP)} Maybe follow up) "
        f"to {DEMO_DB_PATH}"
    )


if __name__ == "__main__":
    main()
