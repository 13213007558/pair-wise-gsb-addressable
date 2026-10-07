#!/usr/bin/env node
// Differential fuzzing harness: generates random domain names and the
// expected UTS 46 results computed by tr46 v4.1.1 (Unicode 15.0.0).
// script/uts46/fuzz.rb compares Addressable::IDNA::UTS46 against it.
//
// The character pool avoids code points whose handling differs between
// the two implementations by design:
//   - code points assigned in Unicode 15.1 (tr46 4.1.1 has 15.0 data)
//   - ContextO code points (tr46 does not implement ContextO)
//   - A-label looking labels ("xn--" prefix is never generated)
//
// Usage: node script/uts46/fuzz.mjs SEED COUNT [TR46_DIR] > cases.jsonl

import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const tr46 = require(process.argv[4] || "tr46");

const seed = Number(process.argv[2] || "1");
const count = Number(process.argv[3] || "1000");

// xorshift32 PRNG for reproducibility
let state = (seed >>> 0) || 1;
function rand() {
  state ^= state << 13; state >>>= 0;
  state ^= state >> 17;
  state ^= state << 5; state >>>= 0;
  return state / 0x100000000;
}
function pick(arr) { return arr[Math.floor(rand() * arr.length)]; }

const pools = [
  "abcdez", "ABCZ", "01239", "-_", "éüßàñ", "ẞ", "ΣσςΛ", "ΪΫ",
  "אבגמ", "معلمني", "١٢", "۱۲", "कषिी्", "‌‍",
  "詹姆斯例", "テストかな", "。．｡", "ＡＢ１", "̧́",
  "͈", "🌹💩", "­͏", "Ａ", "İı",
].map((s) => [...s]); // iterate by code point, not UTF-16 code unit

function randomLabel() {
  const len = 1 + Math.floor(rand() * 8);
  let label = "";
  for (let i = 0; i < len; i++) {
    label += pick(pick(pools));
  }
  return label;
}

function randomDomain() {
  const n = 1 + Math.floor(rand() * 3);
  const labels = [];
  for (let i = 0; i < n; i++) labels.push(randomLabel());
  let domain = labels.join(".");
  // Avoid accidental "xn--" prefixes (A-label handling is covered by
  // dedicated vectors).
  if (/^xn--/i.test(domain)) domain = "q" + domain;
  return domain;
}

for (let i = 0; i < count; i++) {
  const domain = randomDomain();
  const row = { domain };
  for (const transitional of [false, true]) {
    for (const std3 of [false, true]) {
      const r = tr46.toASCII(domain, {
        processingOption: transitional ? "transitional" : "nontransitional",
        useSTD3ASCIIRules: std3,
        checkHyphens: true,
        checkBidi: true,
        checkJoiners: true,
        verifyDNSLength: true,
      });
      row["a" + (transitional ? "t" : "n") + (std3 ? "s" : "r")] = r === null ? "ERROR" : r;
    }
  }
  const u = tr46.toUnicode(domain, {
    processingOption: "nontransitional",
    useSTD3ASCIIRules: false,
    checkHyphens: true,
    checkBidi: true,
    checkJoiners: true,
  });
  if (!u.error) row.u = u.domain;
  console.log(JSON.stringify(row));
}
