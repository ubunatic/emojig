---
title: "German search 'pferd' does not find the horse emoji"
status: open
priority: p2
---

# Issue: German Search "pferd" Does Not Find the Horse Emoji

## Problem

When the picker is run in German locale (`--lang de`), typing `"pferd"` does not yield the horse emoji (`🐎`, `🐴`). 

This is because the emoji database is embedded in English (`data/emoji.json` packed into `src/emojis.bin`), and all fuzzy search queries are matched against English names, descriptions, and keywords. There is currently no translation layer or localized keyword support for search queries.

## Proposed Solutions

### Option 1: Localized Synonym Maps (Spec-Driven)
We can add localized synonym files under `spec/` (e.g., `spec/synonyms_de.json`, `spec/synonyms_es.json`) that map regional terms to their English equivalents:
```json
{
  "description": "German to English translation synonym map.",
  "synonyms": {
    "pferd": ["horse"]
  }
}
```
At pack-time, these can be compressed into localized synonym databases or compiled into `src/emojis.bin` to enable translation-assisted fuzzy searching with zero runtime allocation.

### Option 2: Fully Localized Emoji Annotations
We can ingest multi-language CLDR emoji annotation datasets (e.g. from the Unicode Consortium CLDR project) during database packing, compiling language-specific search index segments so that users can search natively in their configured locale.

## Files to Investigate/Change

1. **`spec/synonyms_de.json`** (new): Initial German translation synonyms.
2. **`scripts/pack_emojis.go`**: Build system packer to merge localized synonyms/annotations into `src/emojis.bin`.
3. **`src/root.zig`**: `search` and `matchTerm` logic to account for localized databases.
