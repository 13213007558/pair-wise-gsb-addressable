#!/usr/bin/env node
// Generates spec/fixtures/uts46_vectors.jsonl: expected UTS 46 results
// for a corpus of domain names, using tr46 v4.1.1 (the reference
// JavaScript implementation of UTS 46, Unicode 15.0.0 data) as the
// oracle.
//
// Only test cases whose expected behavior is identical between Unicode
// 15.0 and 15.1 are generated here: the corpus deliberately avoids the
// code points assigned in Unicode 15.1 (U+2EBF0..U+2EE5D), ContextO
// code points (tr46 does not implement the optional ContextO rules;
// those are covered by hand-written examples in the spec), and trailing
// root dots (tr46 rejects them under verifyDNSLength, while the UTS 46
// VerifyDNSLength rule permits them).
//
// Usage:
//   node script/uts46/generate_vectors.mjs /path/to/tr46-4.1.1 \
//     spec/fixtures/uts46_vectors.jsonl

import { createRequire } from "node:module";
import { writeFileSync } from "node:fs";

const require = createRequire(import.meta.url);
const tr46Dir = process.argv[2];
const outPath = process.argv[3];
if (!tr46Dir || !outPath) {
  console.error("usage: generate_vectors.mjs TR46_DIR OUT.jsonl");
  process.exit(1);
}
const tr46 = require(tr46Dir + "/index.js");

const corpus = [
  // Plain ASCII and case mapping
  "example.com", "EXAMPLE.COM", "ExAmPlE.cOm", "localhost", "a", "a.b.c.d.e",
  "0abc.example", "a-b-c.example",

  // Mapping: fullwidth, ideographic dots, compatibility characters
  "ＡＢＣ.example", "ａｂｃ．ｊｐ", "www。example。com", "www．example．com",
  "www｡example｡com", "ﬁle.example", "①②③.example", "ⅠⅡⅢ.example",
  "ªº.example", "Ångström.example", "Ａ１２３.ｃｏｍ",

  // Mapping: accents and normalization
  "BÜCHER.de", "bücher.de", "MÜNCHEN.de", "İstanbul.example",
  "éxàmple.cóm", "éxample.com", "ΣΊΣΥΦΟΣ.gr", "Μάϊος.gr",
  "Iñtërnâtiônàlizætiøn.example",

  // Deviation characters (ß, ẞ, final sigma, joiners)
  "faß.de", "FASS.de", "Faß.de", "faẞ.de", "ß.de", "ẞ.de",
  "ςigma.gr", "σigma.gr", "ς.gr", "βόλος.gr", "ΒΌΛΟΣ.gr",

  // ContextJ cases: joiners in valid and invalid positions
  "a‌b.example", "a‍b.example",
  "نامه‌ایران.example", "میان‌مار.example",
  "श्री‌राम.example", "श्री‍राम.example",
  "क्‍ष.example", "क्‌ष.example",
  "مرغ‌.example", "‌abc.example", "a‌.example", "‌.example",
  "علی‌‌کلی.example",

  // ContextO cases that PASS (failing cases are hand-written in the spec)
  "l·l.example", "αβ͵γ.example", "א׳.example", "א״.example",
  "カタカナ・テスト.example", "١٢٣.example", "۱۲۳.example",

  // Bidi: valid and invalid combinations
  "אבג.example", "מבחן.example", "مثال.example", "إختبار.example",
  "abcאבג.example", "אבגabc.example", "אבג123.example", "אבג١٢٣.example",
  "אבג1١.example", "123.אבג.example", "abc.אבג.example", "אבג́.example",
  "1אב.example", "אב.123.example", "١٢٣.אבג.example",

  // STD3-sensitive ASCII
  "exa_mple.com", "a b.com", "a~b.com", "a!b.com", "a#b.com", "a%b.com",
  "a&b.com", "a*b.com", "a+b.com", "a/b.com", "a=b.com", "a?b.com",
  "a[b.com", "a]b.com", "a^b.com", "aˋb.com", "a{b.com", "a|b.com",
  "a}b.com", "a\b.com", "a:b.com", "a;b.com", "a<b.com", "a>b.com",
  "a@b.com", "a(b.com", "a)b.com", "a,b.com", "a'b.com", 'a"b.com',
  "a$b.com", "-abc.com", "abc-.com", "-.com", "ab--cd.com", "ab--.com",
  "a--b.com", "xn--abc.com",

  // A-labels (already punycoded), valid and invalid
  "xn--bcher-kva.de", "xn--fa-hia.de", "XN--BCHER-KVA.de",
  "xn--nxasmq6b.example", "xn--zca.de", "xn--kkg.de",
  "xn--a.com", "xn--zckp1cyg1.sblo.jp", "xn--hxa32grf0a.example",
  "xn--fsq.com", "xn--fsqu00a.com",

  // Ignored code points
  "a­b.example", "a͏b.example", "​abc.example", "áb.example",

  // Disallowed and unassigned code points
  "a͈b.example", ".example", "a b.example",
  "ab.example", ".example", "￿.example",
  "𐍐.example", "𳀰.example", "𛿰.example",
  "⯰.example", "𞅀.example",

  // Well-known IDNs
  "παράδειγμα.δοκιμή", "مثال.إختبار", "пример.рф", "例え.jp",
  "テスト.jp", "실례.kr", "उदाहरण.भारत", "உதாரணம்.இந்தியா",
  "münchen.de", "www.詹姆斯.com", "リ宠퐱卄.com", "🌹🌹🌹.ws",
  "碼標準萬國碼.com",

  // Emoji and other disallowed-but-popular characters
  "💩.la", "❤.example", "☃.example", "⌘.example",

  // Length limits
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.com",
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.com",
  "üüüüüüüüüüüüüüüüüüüüüüüüüüüüüüüüüüüüüüüü.de",
  "üüüüüüüüüüüüüüüüüüüüüüüüüüüüüüüüüüüüüüüüü.de",
  "a".repeat(60) + "." + "b".repeat(60) + "." + "c".repeat(60) + "." + "d".repeat(60) + ".com",
  "a".repeat(63) + "." + "b".repeat(63) + "." + "c".repeat(63) + "." + "d".repeat(63) + ".com",

  // Empty labels and dots
  "a..b", ".a.b", "a...b", "..", "...", "a.b..c",

  // Misc edge cases
  "0.0.0.0", "127.0.0.1", "1.2.3.4.5", "a0.example", "0a.example",
];

const lines = [];
const seen = new Set();

function record(direction, transitional, std3, input, expected) {
  const key = JSON.stringify([direction, transitional, std3, input]);
  if (seen.has(key)) return;
  seen.add(key);
  lines.push(JSON.stringify([direction, transitional, std3, input, expected]));
}

for (const domain of corpus) {
  for (const transitional of [false, true]) {
    for (const std3 of [false, true]) {
      const result = tr46.toASCII(domain, {
        processingOption: transitional ? "transitional" : "nontransitional",
        useSTD3ASCIIRules: std3,
        checkHyphens: true,
        checkBidi: true,
        checkJoiners: true,
        verifyDNSLength: true,
      });
      record("ascii", transitional, std3, domain, result === null ? "ERROR" : result);
    }
  }
  for (const std3 of [false, true]) {
    const result = tr46.toUnicode(domain, {
      processingOption: "nontransitional",
      useSTD3ASCIIRules: std3,
      checkHyphens: true,
      checkBidi: true,
      checkJoiners: true,
    });
    // Only error-free ToUnicode results are portable; invalid A-label
    // handling is covered by hand-written examples in the spec.
    if (!result.error) {
      record("unicode", null, std3, domain, result.domain);
    }
  }
}

writeFileSync(outPath, lines.join("\n") + "\n");
console.log("wrote " + lines.length + " vectors to " + outPath);
