const fs = require("fs");
const path = require("path");
const vm = require("vm");

const root = path.resolve(__dirname, "..");

function checkCommonJs(filePath) {
  const absolute = path.join(root, filePath);
  const source = fs.readFileSync(absolute, "utf8");
  new vm.Script(source, { filename: filePath });
}

function extractScripts(html) {
  const scripts = [];
  const pattern = /<script\b([^>]*)>([\s\S]*?)<\/script>/gi;
  let match;
  while ((match = pattern.exec(html)) !== null) {
    const attrs = match[1] || "";
    if (/\bsrc\s*=/.test(attrs)) continue;
    const typeMatch = attrs.match(/\btype\s*=\s*["']?([^"'\s>]+)/i);
    const type = typeMatch ? typeMatch[1].toLowerCase() : "text/javascript";
    if (type && !["text/javascript", "application/javascript", "module"].includes(type)) continue;
    scripts.push(match[2]);
  }
  return scripts;
}

function checkHtmlScripts(filePath) {
  const absolute = path.join(root, filePath);
  const html = fs.readFileSync(absolute, "utf8");
  const scripts = extractScripts(html);
  if (!scripts.length) throw new Error(`No inline scripts found in ${filePath}`);
  scripts.forEach((source, index) => {
    new vm.Script(source, { filename: `${filePath}#script-${index + 1}` });
  });
}

checkCommonJs("server.js");
checkCommonJs("EpsonFiscalClient.js");
checkCommonJs("NexiEcr17Check.js");
checkCommonJs("print-test-report.js");
checkHtmlScripts(path.join("outputs", "gestione-comande-ristorante.html"));

console.log("Syntax checks passed");
