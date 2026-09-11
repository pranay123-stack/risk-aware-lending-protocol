// Browser click-through of the dApp against a running local stack (Anvil + API + indexer + monitor
// + frontend), starting from the demo state (Deploy.s.sol + Demo.s.sol on a fresh Anvil).
//
//   CHROME_PATH=/usr/bin/google-chrome node e2e/ui-flow.mjs
//
// Drives the real UI through the local dev wallet: borrow, oracle outage (the UI must refuse the
// borrow before signing), ETH crash, liquidation. Screenshots land in e2e/output/.
import { mkdirSync } from "node:fs";
import puppeteer from "puppeteer-core";

const BASE = process.env.FRONTEND_URL ?? "http://localhost:3400";
const API = process.env.API_URL ?? "http://127.0.0.1:4400";
const OUT = new URL("./output/", import.meta.url).pathname;
mkdirSync(OUT, { recursive: true });
const BOB = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC";

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH ?? "/usr/bin/google-chrome",
  headless: true,
  userDataDir: OUT + "profile", // throwaway profile inside e2e/output, never the user's
  args: ["--no-first-run", "--window-size=1440,1000"],
  defaultViewport: { width: 1440, height: 1000 },
});
const page = await browser.newPage();
const logs = [];
page.on("console", (m) => m.type() === "error" && logs.push(m.text() + " @ " + (m.location()?.url ?? "")));
page.on("pageerror", (e) => logs.push("pageerror: " + e.message));

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const api = async (p) => (await fetch(API + p)).json();

async function clickText(text, selector = "button") {
  await page.waitForFunction(
    (t, s) => [...document.querySelectorAll(s)].some((b) => b.textContent.includes(t) && !b.disabled),
    { timeout: 20_000 },
    text,
    selector,
  );
  await page.evaluate(
    (t, s) => [...document.querySelectorAll(s)].find((b) => b.textContent.includes(t) && !b.disabled).click(),
    text,
    selector,
  );
}

async function waitText(text, timeout = 30_000) {
  await page.waitForFunction((t) => document.body.innerText.includes(t), { timeout }, text);
}

async function connectAs(label) {
  // wait for the wallet button to mount (the SSR placeholder is a disabled "Wallet" button)
  await page.waitForFunction(() => [...document.querySelectorAll("header button")].some((b) => /Connect wallet|Deployer|Alice|Bob|Carol|Liquidator/.test(b.textContent)), { timeout: 15_000 });
  const already = await page.evaluate((l) => [...document.querySelectorAll("header button")].some((b) => b.textContent.startsWith(l)), label);
  if (already) return;
  await page.evaluate(() => [...document.querySelectorAll("header button")].find((b) => /Connect wallet|Deployer|Alice|Bob|Carol|Liquidator/.test(b.textContent))?.click());
  await page.waitForFunction((l) => [...document.querySelectorAll("header div.absolute button")].some((b) => b.querySelector("span span")?.textContent === l), { timeout: 10_000 }, label);
  await page.evaluate((l) => [...document.querySelectorAll("header div.absolute button")].find((b) => b.querySelector("span span")?.textContent === l).click(), label);
  await page.waitForFunction((l) => [...document.querySelectorAll("header button")].some((b) => b.textContent.includes(l)), { timeout: 10_000 }, label);
}

const step = async (name, fn) => {
  process.stdout.write(`- ${name} ... `);
  try {
    await fn();
    console.log("ok");
  } catch (e) {
    console.log("FAILED");
    await page.screenshot({ path: `${OUT}fail-${name.replace(/\W+/g, "-")}.png` });
    throw e;
  }
};

try {
  const debtBefore = (await api(`/accounts/${BOB}`)).totalDebtUsd;

  await step("connect as Bob via the local dev wallet", async () => {
    await page.goto(`${BASE}/borrow`, { waitUntil: "networkidle2" });
    await connectAs("Bob");
  });

  await step("borrow 500 USDC through the UI", async () => {
    await clickText("USDC");
    await page.type('input[aria-label="Amount"]', "500");
    await waitText("Health factor");
    await clickText("Borrow USDC");
    await waitText("Borrow 500 USDC confirmed");
    const after = (await api(`/accounts/${BOB}`)).totalDebtUsd;
    if (after < debtBefore + 499) throw new Error(`debt did not grow: ${debtBefore} -> ${after}`);
    await page.screenshot({ path: `${OUT}borrow.png` });
  });

  await step("oracle outage (Deployer, oracle lab)", async () => {
    await page.goto(`${BASE}/admin`, { waitUntil: "networkidle2" });
    await connectAs("Deployer");
    await clickText("Oracle lab");
    await waitText("Oracle lab (local mock feeds)");
    // WETH row: take down the primary feed AND make the secondary deviate -> no healthy agreeing source
    await page.evaluate(() => {
      const row = [...document.querySelectorAll("tr")].find((r) => r.innerText.includes("WETH") && r.innerText.includes("Outage"));
      [...row.querySelectorAll("button")].find((b) => b.textContent.trim() === "Outage").click();
    });
    await waitText("WETH primary feed down");
    await page.evaluate(() => {
      const row = [...document.querySelectorAll("tr")].find((r) => r.innerText.includes("WETH") && r.innerText.includes("Stale"));
      [...row.querySelectorAll("button")].find((b) => b.textContent.trim() === "Stale").click();
    });
    await waitText("WETH feeds made stale");
    await page.screenshot({ path: `${OUT}oracle-lab.png` });
  });

  await step("borrow is refused before signing, with a plain-language reason", async () => {
    await page.goto(`${BASE}/borrow`, { waitUntil: "networkidle2" });
    await connectAs("Bob");
    await clickText("USDC");
    await page.waitForSelector('input[aria-label="Amount"]');
    // Bob borrows USDC against WETH; WETH has no trusted price, so the account cannot be valued.
    await waitText("your position cannot be valued");
    await page.type('input[aria-label="Amount"]', "10");
    const disabled = await page.evaluate(() => [...document.querySelectorAll("button")].find((b) => b.textContent.includes("Borrow USDC"))?.disabled);
    if (!disabled) throw new Error("borrow button should be disabled while the account is unpriceable");
    await page.screenshot({ path: `${OUT}oracle-blocked.png` });
  });

  await step("restore the feed, then crash ETH 30%", async () => {
    await page.goto(`${BASE}/admin`, { waitUntil: "networkidle2" });
    await connectAs("Deployer");
    await clickText("Oracle lab");
    await waitText("Oracle lab (local mock feeds)");
    await page.evaluate(() => {
      const row = [...document.querySelectorAll("tr")].find((r) => r.innerText.includes("WETH") && r.innerText.includes("Restore"));
      [...row.querySelectorAll("button")].find((b) => b.textContent.trim() === "Restore").click();
    });
    await waitText("WETH primary restored");
    await page.evaluate(() => {
      const row = [...document.querySelectorAll("tr")].find((r) => r.innerText.includes("WETH") && r.innerText.includes("Heal"));
      [...row.querySelectorAll("button")].find((b) => b.textContent.trim() === "Heal").click();
    });
    await waitText("WETH feeds refreshed");
    await sleep(1500);
    await page.evaluate(() => {
      const row = [...document.querySelectorAll("tr")].find((r) => r.innerText.includes("WETH") && r.innerText.includes("−30%"));
      [...row.querySelectorAll("button")].find((b) => b.textContent.trim() === "−30%").click();
    });
    await waitText("WETH crashed 30%");
    const hf = (await api(`/accounts/${BOB}/health-factor`)).healthFactor;
    if (!(typeof hf === "number" && hf < 1)) throw new Error(`Bob should be liquidatable, HF=${hf}`);
  });

  await step("liquidate Bob as the Liquidator", async () => {
    await sleep(11_000); // one monitor sweep picks Bob up as a candidate
    await page.goto(`${BASE}/liquidations`, { waitUntil: "networkidle2" });
    await connectAs("Liquidator");
    await clickText("Liquidate");
    await waitText("Liquidated 0x3C44");
    await page.screenshot({ path: `${OUT}liquidated.png` });
    const liq = await api(`/liquidations?limit=5`);
    console.log(`\n  liquidations indexed: ${liq.total}`);
  });

  await step("analytics and risk pages render with data", async () => {
    await page.goto(`${BASE}/analytics`, { waitUntil: "networkidle2" });
    await waitText("Supplied vs borrowed");
    await sleep(1500);
    await page.screenshot({ path: `${OUT}analytics.png`, fullPage: true });
    await page.goto(`${BASE}/risk`, { waitUntil: "networkidle2" });
    await waitText("Open alerts");
    await sleep(1000);
    await page.screenshot({ path: `${OUT}risk-after.png`, fullPage: true });
  });
} finally {
  if (logs.length) console.log("browser console errors:\n  " + [...new Set(logs)].slice(0, 10).join("\n  "));
  await browser.close();
}
