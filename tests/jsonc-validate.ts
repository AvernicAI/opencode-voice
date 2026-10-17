// Validate a JSONC file: strip // and /* */ comments plus trailing commas,
// then JSON.parse. Exit 0 when valid, 1 with the parse error otherwise.
const path = process.argv[2];
if (!path) {
  console.log("usage: bun jsonc-validate.ts <file>");
  process.exit(2);
}
const text = await Bun.file(path).text();

function strip(input: string, dropTrailingCommas: boolean): string {
  let out = "";
  let i = 0;
  let inStr = false;
  while (i < input.length) {
    const c = input[i];
    if (inStr) {
      if (c === "\\") {
        out += c + (input[i + 1] ?? "");
        i += 2;
        continue;
      }
      if (c === '"') inStr = false;
      out += c;
      i++;
      continue;
    }
    if (c === '"') {
      inStr = true;
      out += c;
      i++;
      continue;
    }
    if (c === "/" && input[i + 1] === "/") {
      while (i < input.length && input[i] !== "\n") i++;
      continue;
    }
    if (c === "/" && input[i + 1] === "*") {
      i += 2;
      while (i < input.length && !(input[i] === "*" && input[i + 1] === "/")) i++;
      i += 2;
      continue;
    }
    if (dropTrailingCommas && c === ",") {
      let j = i + 1;
      while (j < input.length && /\s/.test(input[j])) j++;
      if (input[j] === "}" || input[j] === "]") {
        i++;
        continue;
      }
    }
    out += c;
    i++;
  }
  return out;
}

try {
  JSON.parse(strip(strip(text, false), true));
  console.log("OK");
  process.exit(0);
} catch (e) {
  console.log(`ERROR: ${(e as Error).message}`);
  process.exit(1);
}
