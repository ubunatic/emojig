<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Group Search Test Coverage

## Status

Groups with dedicated `inTop` tests in `src/ranking_test.zig` (Phase 3 of issue 38):

| Group | Key queries tested | Done |
|-------|-------------------|------|
| Food: fruit | apples, green apple, watermelon | ✅ |
| Food: spicy | chili, spicy | ✅ |
| Food: chips/fries | chips, french fries | ✅ |
| Food: baked | bake, breakfast | ✅ |
| Drinks: social | boba, cheers, celebrate | ✅ |
| Drinks: caffeine | caffeine | ✅ |
| Drinks: ice/cold | ice, cold | ✅ |
| Feelings: positive | happy, hype, wow | ✅ |
| Feelings: negative | sad, nauseated, sick, shocked, dead | ✅ |
| Feelings: tired | tired, sleepy | ✅ |
| Feelings: quiet | silent | ✅ |

Remaining 80+ groups below are open for future test expansion.

---

Here are 40 high-value semantic group examples to expand your search index test bench.
These test your picker's ability to map situational, cultural, and environmental keywords to relevant emojis across food, drinks, and feelings.

### Culinary & Eating Scenarios (1–10)

1. **"bbq" / "grill" / "barbecue"** $\rightarrow$ 🍖, 🍗, 🥩, 🥓, 🌭, 🌶️, 🍺
2. **"fastfood" / "junkfood"** $\rightarrow$ 🍔, 🍟, 🍕, 🌭, 🥪, 🌮, 🥤
3. **"seafood"** $\rightarrow$ 🦀, 🦞, 🦐, 🦑, 🦪, 🍣
4. **"dessert" / "sweet" / "treat"** $\rightarrow$ 🍦, 🍧, 🍨, 🍩, 🍪, 🎂, 🍰, 🧁, 🥧, 🍫, 🍬, 🍭, 🍮, 🍯
5. **"healthy" / "diet" / "vegan"** $\rightarrow$ 🍏, 🥗, 🥦, 🥑, 🥕, 🥒, 🫑, 🍅, 🥬
6. **"cinema" / "movie"** $\rightarrow$ 🍿, 🥤, 🍫, 😱, 🤩
7. **"italian"** $\rightarrow$ 🍕, 🍝, 🧀, 🍷, ☕
8. **"mexican"** $\rightarrow$ 🌮, 🌯, 🌽, 🥑, 🌶️
9. **"asian" / "takeout"** $\rightarrow$ 🍱, 🥟, 🥢, 🍜, 🥠, 🥡, 🍣, 🍛
10. **"picnic" / "snack"** $\rightarrow$ 🥪, 🧀, 🍎, 🍇, 🥨, 🧃

### Beverage Contexts (11–20)

11. **"caffeine" / "morning" / "energy"** $\rightarrow$ ☕, 🍵, 🧋, 🥱, 🤩
12. **"bar" / "pub" / "nightlife"** $\rightarrow$ 🍺, 🍻, 🍷, 🍸, 🍹, 🥃, 🍾, 🥴
13. **"hangover"** $\rightarrow$ 🤢, 🤮, 🤕, 🥴, 💀, ☕, 💧, 🥱
14. **"toast" / "celebration" / "cheers"** $\rightarrow$ 🥂, 🍻, 🍾, 🥳
15. **"summer" / "beach" / "tropical"** $\rightarrow$ 🍹, 🥥, 🍍, 🍉, 🍦, 🥵, 😎
16. **"winter" / "cozy" / "cold"** $\rightarrow$ ☕, 🫖,  soup $\rightarrow$ 🍲, 🍜, 🥶, 🫕
17. **"dairy"** $\rightarrow$ 🥛, 🧀, 🧈, 🍦, 🍨
18. **"fruit_juice"** $\rightarrow$ 🧃, 🥤, 🍊, 🍎, 🍇, 🍓
19. **"hydration" / "water"** $\rightarrow$ 🥛, 🧊, 🥤, 💧, 🥵
20. **"tea_time"** $\rightarrow$ 🫖, 🍵, 🧁, 🍪, 🍰, 🥮

### Negative & Stress Emotional States (21–30)

21. **"angry" / "mad" / "rage"** $\rightarrow$ 😠, 😡, 🤬, 😤, 👿
22. **"shocked" / "surprised" / "wtf"** $\rightarrow$ 😮, 😯, 😲, 😳, 😱, 🤯, 🫨
23. **"tired" / "sleepy" / "lazy"** $\rightarrow$ 🥱, 😴, 😪, 🤤, 😔, 💤
24. **"scared" / "fear" / "panic"** $\rightarrow$ 😨, 😰, 😱, 🫨, 😖, 🫣
25. **"sad" / "depressed" / "cry"** $\rightarrow$ 🙁, ☹️, 😔, 😢, 😭, 🥲, 😞, 😓
26. **"bored" / "annoyed" / "whatever"** $\rightarrow$ 😑, 😐, 😒, 🙄, 😮‍💨
27. **"nervous" / "anxious" / "stressed"** $\rightarrow$ 😬, 😰, 😓, 🫣, 🫨
28. **"disgusted" / "gross" / "eww"** $\rightarrow$ 🤢, 🤮, 😒, 😑
29. **"embarrassed" / "shame" / "oops"** $\rightarrow$ 😳, 🫣, 😅, 🫠
30. **"evil" / "mischievous" / "bad"** $\rightarrow$ 😈, 👿, 💀, ☠️, 😏

### Positive & Social Emotional States (31–40)

31. **"happy" / "joy" / "smile"** $\rightarrow$ 😀, 😃, 😄, 😁, 😆, 😊, 🙂
32. **"love" / "romantic" / "heart"** $\rightarrow$ 🥰, 😍, 😘, 😚, 😙
33. **"laugh" / "lol" / "funny"** $\rightarrow$ 😂, 🤣, 😆, 😅, 😜
34. **"cool" / "chill" / "relaxed"** $\rightarrow$ 😎, 😌, 😏, 🍹, 🧊
35. **"smart" / "nerd" / "intellectual"** $\rightarrow$ 🤓, 🧐, 🤔, 🧠
36. **"money" / "rich" / "wealth"** $\rightarrow$ 🤑, 💵, 💰, 💳
37. **"flirt" / "wink" / "sassy"** $\rightarrow$ 😉, 😏, 😜, 🤪, 😘
38. **"proud" / "accomplished" / "win"** $\rightarrow$ 🥳, 🤩, 😤, 😎
39. **"secret" / "quiet" / "shh"** $\rightarrow$ 🤫, 🤐, 😶
40. **"crazy" / "wild" / "goofy"** $\rightarrow$ 🤪, 🫨, 🥳, 🥴

This setup catches edge cases where a fuzzy match scorer accidentally pushes irrelevant emojis into your top search result view.


Here are more:

Here are 40 additional semantic group examples to expand your test suite, diving into specialized culinary themes, distinct professional/environmental mindsets, complex mood blends, and physical sensations.

### Specialty Foods & Flavors (41–50)

41. **"baking" / "bakery" / "dough"** $\rightarrow$ 🍞, 🥐, 🥖, 🫓, 🥨, 🥯, 🥞, 🧇, 🥧, 🥮
42. **"spicy" / "hot_food" / "burn"** $\rightarrow$ 🌶️, 🥵, 🫚, 🍛, 🍲
43. **"carnivore" / "meat"** $\rightarrow$ 🍖, 🍗, 🥩, 🥓, 🍔
44. **"movie_night" / "munchies"** $\rightarrow$ 🍿, 🍟, 🍪, 🍫, 🥤
45. **"soup" / "broth" / "stew"** $\rightarrow$ 🍲, 🍜, 🥣
46. **"breakfast_food"** $\rightarrow$ 🍳, 🥓, 🥞, 🧇, 🥯, 🍞, 🥛
47. **"sauce" / "condiment"** $\rightarrow$ 🧈, 🧂, 🥫, 🍯
48. **"seafood_dinner"** $\rightarrow$ 🐟, 🦪, 🦞, 🦀, 🍤, 🍣
49. **"citrus" / "sour"** $\rightarrow$ 🍋, 🍊, 🫨
50. **"savory" / "umami"** $\rightarrow$ 🍄, 🧄, 🧅, 🥩, 🧀, 🫘

### Social Drinking & Coffee Culture (51–60)

51. **"pub_crawl" / "drinking"** $\rightarrow$ 🍺, 🍻, 🥂, 🍷, 🥃, 🥴
52. **"iced_drink" / "refreshment"** $\rightarrow$ 🧊, 🥤, 🧋, 🍹
53. **"wine_tasting"** $\rightarrow$ 🍷, 🍾, 🥂, 🍇, 🧀
54. **"tea_party" / "herbal"** $\rightarrow$ 🫖, 🍵, 🍋, 🍯, 🧁
55. **"cocktail_hour"** $\rightarrow$ 🍸, 🍹, 🥂, 🍋, 🍍, 😎
56. **"milkbar" / "shake"** $\rightarrow$ 🥛, 🧋, 🍦, 🍨, 🍓, 🍫
57. **"celebrate_win" / "popping"** $\rightarrow$ 🍾, 🥂, 🥳, 🤩
58. **"non_alcoholic" / "soft_drink"** $\rightarrow$ 🥤, 🧃, 🥛, 💧
59. **"bitter" / "dark_roast"** $\rightarrow$ ☕, 🍫
60. **"shot" / "spirits"** $\rightarrow$ 🥃, 🍶, 🍋, 🥴

### Physical Sensations & Illness (61–70)

61. **"fever" / "sunstroke" / "sweating"** $\rightarrow$ 🥵, 🌡️, 🤒, 💧
62. **"freezing" / "shivering" / "winter_cold"** $\rightarrow$ 🥶, 🫨, ❄️, 🧊
63. **"nausea" / "food_poisoning"** $\rightarrow$ 🤢, 🤮, 🥴, 🤢
64. **"allergy" / "hayfever"** $\rightarrow$ 🤧, 💧, 🥱, 👁️
65. **"injury" / "accident" / "hurt"** $\rightarrow$ 🤕, 😢, 😭, 💥
66. **"exhausted" / "burnout"** $\rightarrow$ 😫, 😩, 😓, 🥱, 😮‍💨, 💤
67. **"fainting" / "dizzy"** $\rightarrow$ 😵, 😵‍💫, 🫨, 🫠
68. **"headache" / "migraine"** $\rightarrow$ 🤕, 🤯, 😫, 😑, ⚡
69. **"drooling" / "starving"** $\rightarrow$ 🤤, 😋, 🍕, 🍔, 🥩
70. **"blinded" / "bright"** $\rightarrow$ 😎, 🫣, 😲, ☀️

### Complex, Subversive & Nuanced Moods (71–80)

71. **"skeptical" / "doubt" / "unconvinced"** $\rightarrow$ 🤨, 🤔, 🙄, 😒, 😑
72. **"clueless" / "shrug" / "dunno"** $\rightarrow$ 🤷, 🫨, ❔, 😶
73. **"sarcasm" / "smug" / "gotcha"** $\rightarrow$ 😏, 🙃, 😉, 😜
74. **"speechless" / "no_comment"** $\rightarrow$ 😶, 😐, 😑, 🫥, 🤐
75. **"melting" / "embarrassed_hot" / "overwhelmed"** $\rightarrow$ 🫠, 😳, 🫣, 😅
76. **"starstruck" / "celebrity" / "glam"** $\rightarrow$ 🤩, 😎, ✨, 🌟
77. **"plotting" / "scheming" / "sinister"** $\rightarrow$ 😈, 😏, 🕵️, 🧠
78. **"dead" / "dying_laughing" / "finished"** $\rightarrow$ 💀, ☠️, 😂, 🤣
79. **"grief" / "heartbroken"** $\rightarrow$ 😭, 😢, 💔, 😔, 🖤
80. **"fake_smile" / "masking" / "internal_screaming"** $\rightarrow$ 🙂, 🙃, 🥲, 😅, 😬

And some more:

Here are another 40 semantic group examples, pushing deeper into micro-contexts, dietary preferences, drinking habits, and specific subtle facial expressions or physical reactions.

### Dietary & Ingredient Nuances (81–90)

81. **"orchard" / "fresh_fruit"** $\rightarrow$ 🍎, 🍏, 🍐, 🍑, 🍒, 🍓
82. **"veggies" / "greens" / "produce"** $\rightarrow$ 🥕, 🥦, 🥬, 🥒, 🫑, 🍅, 🫛
83. **"carbs" / "starch" / "bakery"** $\rightarrow$ 🍞, 🥔, 🥐, 🥖, 🥯, 🥞, 🧇, 🍝
84. **"sweet_tooth" / "sugar_rush"** $\rightarrow$ 🍫, 🍬, 🍭, 🍩, 🍪, 🎂, 🧁
85. **"condiments" / "seasoning"** $\rightarrow$ 🧂, 🧈, 🫚, 🧄, 🧅, 🍯
86. **"tropical_fruit"** $\rightarrow$ 🍌, 🍉, 🍍, 🥭, 🥥, 🥝
87. **"breakfast_sweet"** $\rightarrow$ 🥞, 🧇, 🍩, 🥐, 🍯, 🧃
88. **"finger_food" / "appetizer"** $\rightarrow$ 🥨, 🧀, 🥜, 🌰, 🫓
89. **"citrus_sour" / "acidic"** $\rightarrow$ 🍋, 🍊, 🫨
90. **"stew_ingredients"** $\rightarrow$ 🥩, 🥔, 🥕, 🧅, 🧄, 🍄, 🫘

### Drink Scenarios & Vessels (91–100)

91. **"happy_hour" / "lounge"** $\rightarrow$ 🍸, 🍹, 🍷, 🥃, 😎
92. **"caffeine_fix" / "all_nighter"** $\rightarrow$ ☕, 🧋, 🥱, 🧠, 💻
93. **"party_drinks" / "pregame"** $\rightarrow$ 🍾, 🍻, 🥂, 🍺, 🥃
94. **"hot_drink" / "winter_warmer"** $\rightarrow$ ☕, 🫖, 🍵, 🥶
95. **"ice_cold" / "freezing_drink"** $\rightarrow$ 🧊, 🥤, 🧋, 🍺, 🥶
96. **"healthy_drink" / "detox"** $\rightarrow$ 🍵, 💧, 🥛, 🧃, 🍏
97. **"cheers" / "salute"** $\rightarrow$ 🥂, 🍻, 🥃, 🥳
98. **"nightcap" / "late_drink"** $\rightarrow$ 🥃, 🍷, 😴, 🌙
99. **"soft_drink" / "fizz"** $\rightarrow$ 🥤, 🧃, 🧊
100. **"brewery" / "draft_beer"** $\rightarrow$ 🍺, 🍻, 🪵

### Physical States & Body Sensations (101–110)

101. **"sunburn" / "heatwave" / "sweat"** $\rightarrow$ 🥵, 🌡️, ☀️, 💧
102. **"chills" / "frostbite" / "shivering"** $\rightarrow$ 🥶, 🫨, ❄️, 🧊
103. **"sea_sick" / "motion_sickness"** $\rightarrow$ 🤢, 🤮, 🥴, 🫨, 🌊
104. **"sneezing" / "cold_flu"** $\rightarrow$ 🤧, 🤒, 😷, 💧
105. **"fainting" / "blackout"** $\rightarrow$ 😵, 😵‍💫, 🫨, 🫠, 💀
106. **"concussion" / "head_injury"** $\rightarrow$ 🤕, 🫨, 😵, 💥
107. **"yawning" / "exhaustion"** $\rightarrow$ 🥱, 💤, 😴, 😫, 😩
108. **"stuffed" / "full" / "food_coma"** $\rightarrow$ 🫃, 😮‍💨, 🥱, 😴, 🍕
109. **"crying_laughing" / "dying"** $\rightarrow$ 😂, 🤣, 💀, ☠️
110. **"jaw_drop" / "gasp"** $\rightarrow$ 😲, 😮, 🫨, 😳, 😱

### Social Expressions & Mindsets (111–120)

111. **"unimpressed" / "side_eye"** $\rightarrow$ 😒, 🤨, 🙄, 😑
112. **"poker_face" / "no_expression"** $\rightarrow$ 😐, 😑, 😶, 🫥
113. **"smug" / "i_told_you_so"** $\rightarrow$ 😏, 😎, 😉, 🙃
114. **"nervous_laugh" / "cringe"** $\rightarrow$ 😅, 😬, 🫠, 🫨
115. **"hush" / "keep_quiet"** $\rightarrow$ 🤫, 🤐, 😶
116. **"star_struck" / "fangirl"** $\rightarrow$ 🤩, 😍, 🥰, ✨
117. **"scheming" / "mischief"** $\rightarrow$ 😈, 😏, 🧠, 👁️
118. **"mind_blown" / "shock"** $\rightarrow$ 🤯, 😱, 💥, 😲
119. **"pensive" / "overthinking"** $\rightarrow$ 😔, 🤔, 😓, 🙄, 😮‍💨
120. **"goofy" / "silly" / "derp"** $\rightarrow$ 🤪, 😜, 👅, 🥴




