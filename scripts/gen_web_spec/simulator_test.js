// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { test } = require('node:test');

const context = vm.createContext({ document: { addEventListener() {} } });
for (const file of ['webspec.js', 'emojis.js', 'simulator.js']) {
  vm.runInContext(fs.readFileSync(`website/demo/simulator/${file}`, 'utf8'), context);
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

test('shell commands share completion, dispatch and help in standalone and embedded use', () => {
  context.window = {matchMedia: () => ({matches: false, addEventListener() {}})};
  context.document.getElementById = () => null;
  const shell = vm.runInContext('new EmojigSimulator()', context);
  shell.render = () => {};
  const complete = (input) => {
    shell.setInput(input);
    shell.handleTabComplete();
    return shell.shellInput;
  };
  assert.equal(complete('l'), 'ls');
  assert.equal(shell.shellLines.at(-1).text, 'ls  ll');
  assert.equal(complete('r'), 'rmdir');
  assert.equal(shell.shellLines.at(-1).text, 'rmdir  rm');
  assert.equal(complete('e'), 'echo');
  assert.equal(shell.shellLines.at(-1).text, 'echo  env  emojig');
  assert.equal(complete('sudo ec'), 'sudo echo');
  for (const name of shell.getShellCommandNames()) assert.equal(complete(name), name);
  assert.equal(complete('cat RE'), 'cat README.md');
  shell.setInput('ec suffix');
  shell.cursorPos = 2;
  shell.handleTabComplete();
  assert.equal(shell.shellInput, 'echo suffix');
  assert.equal(shell.cursorPos, 4);
  assert.equal(complete('unknown'), 'unknown');
  shell.registerShellCommand('launch', function (args) {
    this.shellLines.push({kind: 'out', text: args.join(' ')});
  });
  assert.equal(complete('la'), 'launch');
  shell.setInput('sudo launch hello registry');
  shell.executeShell();
  assert.equal(shell.shellLines.at(-1).text, 'hello registry');
  assert.equal(shell.shellHistory.at(-1), 'sudo launch hello registry');
  shell.setInput('help');
  shell.executeShell();
  assert.ok(shell.shellLines.at(-2).text.includes('launch'));
  for (const command of ['emojig', 'sudo emojig']) {
    shell.mode = 'shell';
    shell.setInput(command);
    shell.executeShell();
    assert.equal(shell.mode, 'tui');
    assert.equal(shell.shellInput, '');
    assert.equal(shell.shellHistory.at(-1), command);
  }
  shell.mode = 'shell';
  shell.isFocused = true;
  shell.setInput('ec');
  let prevented = false;
  const tab = {key: 'Tab', preventDefault() { prevented = true; }};
  shell.handleKeydown({...tab, shiftKey: true});
  assert.equal(prevented, false);
  assert.equal(shell.shellInput, 'ec');
  shell.handleKeydown(tab);
  assert.equal(prevented, true);
  assert.equal(shell.shellInput, 'echo');
});

test('new builtin cases need no separate completion inventory', () => {
  const source = fs.readFileSync('website/demo/simulator/simulator.js', 'utf8');
  const extended = source.replace('      case "echo":', '      case "extra-command":\n      case "echo":');
  const probe = vm.createContext({document: {addEventListener() {}}, window: context.window});
  vm.runInContext(extended, probe);
  const shell = vm.runInContext('new EmojigSimulator()', probe);
  shell.render = () => {};
  shell.setInput('extra-');
  shell.handleTabComplete();
  assert.equal(shell.shellInput, 'extra-command');
});
