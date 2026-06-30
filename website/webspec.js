/*
 * SPDX-FileCopyrightText: 2026 Uwe Jugel
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

// generated from spec/*.json by scripts/gen_web_spec; do not edit by hand
const EMOJIG_WEB_SPEC = {
  "generated_from": [
    "spec/layout.json",
    "spec/strings.json",
    "spec/categories.json",
    "spec/boxart.json",
    "spec/braille.json"
  ],
  "layout": {
    "cols": 8,
    "rows": 10,
    "width": 36,
    "layout_overhead": 6,
    "max_query_len": 63,
    "max_results": 1280,
    "min_cols": 5,
    "min_rows": 3,
    "max_cols": 16,
    "max_rows": 16
  },
  "strings": {
    "help_lines": [
      "😀 \u001b]8;;https://ubunatic.com/emojig\u001b\\ubunatic.com/emojig\u001b]8;;\u001b\\",
      "",
      " ⌨️|abc|↕↔ Search, Navigate",
      " 🖱️|↵|Esc  Select, Exit",
      " ␣ (Space) Multi-select",
      " ⭾ (Tab)   Switch category 🗘 ",
      " ??        More…"
    ],
    "help_lines_more": [
      "😀 \u001b]8;;https://ubunatic.com/emojig\u001b\\ubunatic.com/emojig\u001b]8;;\u001b\\",
      "",
      " e:abc 🔍 Emojis only",
      " t:abc 🔍 Symbols only",
      " b:abc 🔍 Box art only",
      " a b 🔍   Match all words",
      " ␣/↵ pick  ⇧↵ done",
      " ⌫        Back…"
    ],
    "cursor_left": "⌜",
    "cursor_right": "⌟",
    "multi_select_mark": "➜",
    "search_placeholder": "search…",
    "search_prompt": " 🔍 ",
    "status_default": {
      "on_view": " ?:help  ↕↔|↵|Esc",
      "on_view_wide": " ?:help e:img t:txt  ↕↔|↵|Esc",
      "on_search": " {count}  ↕↔|↵|Esc",
      "on_search_wide": " {count} e:img t:txt  ↕↔|↵|Esc"
    }
  },
  "categories": [
    {
      "name": "smileys",
      "short": "smiley",
      "icon": "😀",
      "switcher": true,
      "synonyms": [
        "smiley",
        "face",
        "smile",
        "emotion",
        "grin",
        "laugh",
        "cry"
      ]
    },
    {
      "name": "people",
      "short": "person",
      "icon": "👍",
      "switcher": true,
      "synonyms": [
        "people",
        "person",
        "body",
        "hand",
        "man",
        "woman",
        "child",
        "baby",
        "boy",
        "girl"
      ]
    },
    {
      "name": "animals",
      "short": "animal",
      "icon": "🐾",
      "switcher": true,
      "synonyms": [
        "animal",
        "nature",
        "wildlife",
        "creature",
        "pet",
        "fauna"
      ]
    },
    {
      "name": "food",
      "short": "food",
      "icon": "🍴",
      "switcher": true,
      "synonyms": [
        "food",
        "drink",
        "eat",
        "meal",
        "beverage",
        "fruit",
        "vegetable"
      ]
    },
    {
      "name": "travel",
      "short": "travel",
      "icon": "✈️",
      "switcher": true,
      "synonyms": [
        "travel",
        "vehicle",
        "transport",
        "place",
        "location",
        "car",
        "boat",
        "plane",
        "train"
      ]
    },
    {
      "name": "activities",
      "short": "activity",
      "icon": "⚽",
      "switcher": true,
      "synonyms": [
        "activity",
        "sport",
        "game",
        "hobby",
        "play"
      ]
    },
    {
      "name": "plants",
      "short": "plant",
      "icon": "",
      "switcher": false,
      "synonyms": [
        "plant",
        "tree",
        "trees",
        "leaf",
        "leaves",
        "grass",
        "seed",
        "cactus",
        "wood"
      ]
    },
    {
      "name": "flowers",
      "short": "flower",
      "icon": "",
      "switcher": false,
      "synonyms": [
        "flower",
        "flowers",
        "blossom",
        "rose",
        "tulip",
        "sunflower",
        "cherry",
        "petal"
      ]
    },
    {
      "name": "insects",
      "short": "insect",
      "icon": "",
      "switcher": false,
      "synonyms": [
        "insect",
        "insects",
        "bug",
        "bugs",
        "fly",
        "spider",
        "butterfly",
        "bee",
        "ant"
      ]
    },
    {
      "name": "birds",
      "short": "bird",
      "icon": "",
      "switcher": false,
      "synonyms": [
        "bird",
        "birds",
        "duck",
        "owl",
        "eagle",
        "chicken"
      ]
    },
    {
      "name": "fish",
      "short": "fish",
      "icon": "",
      "switcher": false,
      "synonyms": [
        "fish",
        "fishes",
        "shark",
        "marine",
        "crab",
        "lobster",
        "shrimp",
        "octopus",
        "blowfish",
        "jellyfish",
        "seahorse"
      ]
    },
    {
      "name": "drinks",
      "short": "drink",
      "icon": "",
      "switcher": false,
      "synonyms": [
        "drink",
        "drinks",
        "beverage",
        "beverages",
        "coffee",
        "tea",
        "wine",
        "beer",
        "juice"
      ]
    },
    {
      "name": "tools",
      "short": "tool",
      "icon": "",
      "switcher": false,
      "synonyms": [
        "tool",
        "tools",
        "hammer",
        "wrench",
        "screwdriver",
        "gear",
        "axe"
      ]
    },
    {
      "name": "clothes",
      "short": "clothing",
      "icon": "",
      "switcher": false,
      "synonyms": [
        "clothing",
        "clothes",
        "wear",
        "shirt",
        "pants",
        "dress",
        "shoe",
        "shoes",
        "hat"
      ]
    },
    {
      "name": "buildings",
      "short": "building",
      "icon": "",
      "switcher": false,
      "synonyms": [
        "building",
        "buildings",
        "house",
        "home",
        "office",
        "castle",
        "school",
        "tower"
      ]
    },
    {
      "name": "instruments",
      "short": "instrument",
      "icon": "",
      "switcher": false,
      "synonyms": [
        "instrument",
        "instruments",
        "music",
        "musical",
        "guitar",
        "piano",
        "violin",
        "drum"
      ]
    },
    {
      "name": "sports",
      "short": "sport",
      "icon": "",
      "switcher": false,
      "synonyms": [
        "sport",
        "sports",
        "ball",
        "soccer",
        "football",
        "tennis",
        "game"
      ]
    },
    {
      "name": "weather",
      "short": "weather",
      "icon": "",
      "switcher": false,
      "synonyms": [
        "weather",
        "sun",
        "cloud",
        "clouds",
        "rain",
        "snow",
        "wind",
        "storm"
      ]
    },
    {
      "name": "objects",
      "short": "object",
      "icon": "💡",
      "switcher": true,
      "synonyms": [
        "object",
        "tool",
        "item",
        "device",
        "clothing",
        "book",
        "office"
      ]
    },
    {
      "name": "symbols",
      "short": "symbol",
      "icon": "🔣",
      "switcher": true,
      "synonyms": [
        "symbol",
        "sign",
        "mark",
        "heart",
        "arrow",
        "geometric"
      ]
    },
    {
      "name": "flags",
      "short": "flag",
      "icon": "🚩",
      "switcher": true,
      "synonyms": [
        "flag",
        "banner",
        "country"
      ]
    },
    {
      "name": "clocks",
      "short": "clock",
      "icon": "",
      "switcher": false,
      "synonyms": [
        "clock",
        "time",
        "watch"
      ]
    },
    {
      "name": "blocks",
      "short": "block",
      "icon": "",
      "switcher": false,
      "synonyms": [
        "block",
        "square"
      ]
    },
    {
      "name": "borders",
      "short": "border",
      "icon": "",
      "switcher": false,
      "synonyms": [
        "border",
        "frame"
      ]
    },
    {
      "name": "shades",
      "short": "shade",
      "icon": "",
      "switcher": false,
      "synonyms": [
        "shade",
        "gradient"
      ]
    }
  ],
  "filters": {
    "box_art": {
      "min_codepoint": 8629,
      "max_codepoint": 11134,
      "penalty": 150,
      "count": 96
    },
    "braille": {
      "min_codepoint": 10240,
      "max_codepoint": 10495,
      "penalty": 150,
      "count": 256
    }
  }
};
