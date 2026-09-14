// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { test } = require('node:test');

const context = vm.createContext({ document: { addEventListener() {} } });
for (const file of ['webspec.js', 'emojis.js', 'simulator.js']) {
  vm.runInContext(fs.readFileSync(`website/${file}`, 'utf8'), context);
}
const sim = vm.runInContext(`Object.assign(Object.create(EmojigSimulator.prototype), {
  webSpec: EMOJIG_WEB_SPEC, maxResults: EMOJIG_WEB_SPEC.layout.max_results, query: ''
})`, context);
const db = vm.runInContext('EMOJI_DB', context);

test('b: excludes superscripts in both listing and scored searches', () => {
  sim.query = 'b:superscript';
  assert.equal(sim.getFilteredMatches().length, 0);
  sim.query = 'b:';
  const matches = sim.getFilteredMatches();
  for (const digit of '⁰¹²³⁴⁵⁶⁷⁸⁹') {
    assert.ok(!matches.some(item => item.emoji === digit), digit);
  }
  for (const glyph of ['─', '█', '🬀', '🬻']) {
    assert.ok(matches.some(item => item.emoji === glyph), glyph);
  }
});

test('superscripts receive their full fuzzy score without box-art penalty', () => {
  sim.query = 'superscript';
  const matches = sim.getFilteredMatches();
  for (const digit of '⁰¹²³⁴⁵⁶⁷⁸⁹') {
    const item = db.find(item => item[0] === digit);
    const result = matches.find(item => item.emoji === digit);
    assert.ok(result, digit);
    assert.equal(result.score, sim.fuzzyMatch(sim.query, item[2]), digit);
  }
});

test('box-art classification uses tight Unicode bands', () => {
  for (const cp of [0x2500, 0x259f, 0x1fb00, 0x1fb3b]) {
    assert.equal(sim.isBoxArt(String.fromCodePoint(cp)), true, cp.toString(16));
  }
  for (const cp of [0xb7, 0x2071, 0x21b5, 0x232b, 0x24ff, 0x25a0,
    0x2800, 0x2bbe, 0x1f600, 0x1faff, 0x1fb3c]) {
    assert.equal(sim.isBoxArt(String.fromCodePoint(cp)), false, cp.toString(16));
  }
});
