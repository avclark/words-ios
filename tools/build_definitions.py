#!/usr/bin/env python3
"""Build the bundled definitions file: ENABLE ∩ WordNet 3.1.

Output format (defs.tsv): WORD\tpos1: gloss1 | pos2: gloss2
- Uppercase word, senses joined by ' | ', at most one sense per POS,
  at most 3 POS entries, example sentences stripped from glosses.
- Irregular inflections from the .exc files are emitted as their own
  entries pointing at the base word's gloss (MEN -> gloss of MAN).
Regular inflections (-S/-ED/-ING/...) are handled at runtime in Swift.
"""
import re, sys

DICT = "dict"
ENABLE = "/Users/avclark/Projects/words/Words/Words/enable1.txt"
OUT = "defs.tsv"

enable = set()
with open(ENABLE) as f:
    for line in f:
        w = line.strip().upper()
        if w:
            enable.add(w)
print(f"ENABLE: {len(enable)}", file=sys.stderr)

POS_LABEL = {"n": "n.", "v": "v.", "a": "adj.", "s": "adj.", "r": "adv."}
POS_ORDER = {"n.": 0, "v.": 1, "adj.": 2, "adv.": 3}

def clean_gloss(g):
    # Drop quoted example sentences; keep the definition part.
    g = g.split('; "')[0].strip().rstrip(';').strip()
    g = re.sub(r"\s+", " ", g)
    return g

# word (upper) -> {pos_label: first gloss seen}  (data files are ordered by
# synset offset, not frequency; index files give frequency order, so read
# index.* for sense order and data.* for glosses)
glosses = {}   # (pos_char, offset) -> gloss
words_in_synset = {}
for pos_char, fname in [("n", "data.noun"), ("v", "data.verb"),
                        ("a", "data.adj"), ("r", "data.adv")]:
    with open(f"{DICT}/{fname}", encoding="latin-1") as f:
        for line in f:
            if line.startswith("  "):
                continue
            head, _, gloss = line.partition("|")
            parts = head.split()
            offset = parts[0]
            glosses[(pos_char, offset)] = clean_gloss(gloss)

entries = {}  # WORD -> {pos_label: gloss}
for pos_char, fname in [("n", "index.noun"), ("v", "index.verb"),
                        ("a", "index.adj"), ("r", "index.adv")]:
    label = POS_LABEL[pos_char]
    with open(f"{DICT}/{fname}", encoding="latin-1") as f:
        for line in f:
            if line.startswith("  "):
                continue
            parts = line.split()
            lemma = parts[0]
            if "_" in lemma or "-" in lemma or "." in lemma or "'" in lemma:
                continue
            word = lemma.upper()
            if word not in enable:
                continue
            # index format: lemma pos synset_cnt p_cnt [ptrs] sense_cnt
            # tagsense_cnt offset0 offset1... — offsets in frequency order.
            first_offset = parts[-int(parts[2])]  # first of the offset list
            g = glosses.get((pos_char, first_offset))
            if not g:
                continue
            entries.setdefault(word, {}).setdefault(label, g)

print(f"direct entries: {len(entries)}", file=sys.stderr)

# Irregular inflections: adj.exc etc. map inflected -> base form(s).
irregular = 0
for pos_char, fname in [("n", "noun.exc"), ("v", "verb.exc"),
                        ("a", "adj.exc"), ("r", "adv.exc")]:
    label = POS_LABEL[pos_char]
    with open(f"{DICT}/{fname}", encoding="latin-1") as f:
        for line in f:
            parts = line.split()
            if len(parts) < 2:
                continue
            infl, base = parts[0].upper(), parts[1].upper()
            if "_" in infl or infl not in enable or infl in entries:
                continue
            base_entry = entries.get(base)
            if base_entry and label in base_entry:
                entries.setdefault(infl, {})[label] = base_entry[label]
                irregular += 1
print(f"+irregular: {irregular}, total: {len(entries)}", file=sys.stderr)

with open(OUT, "w") as f:
    for word in sorted(entries):
        senses = sorted(entries[word].items(), key=lambda kv: POS_ORDER[kv[0]])[:3]
        joined = " | ".join(f"{p} {g}" for p, g in senses if g)
        if joined:
            f.write(f"{word}\t{joined}\n")

import os
print(f"wrote {OUT}: {os.path.getsize(OUT)} bytes", file=sys.stderr)
