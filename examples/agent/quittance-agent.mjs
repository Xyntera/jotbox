#!/usr/bin/env node
/**
 * Quittance Skill — Agent Invocation Harness
 * ----------------------------------------
 * A runnable demonstration that an AI agent can invoke the Quittance skill exactly the way
 * the Pharos Skill Engine prescribes:
 *
 *   1. read SKILL.md                         (discover the Capability Index)
 *   2. match the user's natural-language intent to a capability row
 *   3. read references/quittance.md            (the exact cast/forge command for that capability)
 *   4. read assets/networks.json             (RPC URL + chain id)
 *   5. for write ops: run the Write Operation Pre-checks
 *   6. execute the `cast` command
 *   7. parse the output per the reference file's "Output Parsing" rules
 *
 * The intent → capability matcher here is a small deterministic router. In production the
 * Pharos Skill Engine's LLM does this step by reading SKILL.md; this harness stands in for
 * that LLM so the whole flow can be run and tested end-to-end on-chain.
 *
 * Usage:
 *   PRIVATE_KEY=0x... node examples/agent/quittance-agent.mjs "<natural language request>"
 *
 * Examples:
 *   node examples/agent/quittance-agent.mjs "what is my Quittance balance?"
 *   node examples/agent/quittance-agent.mjs "deposit 0.03 PHRS into Quittance"
 *   node examples/agent/quittance-agent.mjs "pay 0.004 PHRS to 0x00000000000000000000000000000000C0ffee00 for invoice-777"
 *   node examples/agent/quittance-agent.mjs "verify a payment of 0.004 PHRS to 0x...C0ffee00 for invoice-777"
 *   node examples/agent/quittance-agent.mjs "withdraw 0.01 PHRS from Quittance"
 */

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, "..", "..");
const ZERO = "0x0000000000000000000000000000000000000000";

// ---- config the agent reads from the skill package ----------------------------------
const networks = JSON.parse(readFileSync(resolve(ROOT, "assets/networks.json"), "utf8"));
const NET = networks.pharos_atlantic_testnet;
const RPC = process.env.RPC || NET.rpcUrl;
const QUIT = process.env.QUIT || "0xd872C6F530c2E1055a522B1978CA99FE65B99F56";
const KEY = process.env.PRIVATE_KEY;

const AUTH_TUPLE = "(address,address,address,uint256,bytes32,uint256,uint256)";

// ---- tiny presentation helpers ------------------------------------------------------
const log = (s = "") => console.log(s);
const step = (n, s) => console.log(`\x1b[36m[agent ${n}]\x1b[0m ${s}`);
const cmd = (s) => console.log(`         \x1b[90m$ ${s}\x1b[0m`);

function cast(args, { send = false } = {}) {
  cmd(`cast ${args.join(" ")}`);
  if (send && !KEY) throw new Error("PRIVATE_KEY env var required for write operations");
  return execFileSync("cast", args, { encoding: "utf8" }).trim();
}

// ---- read SKILL.md and parse the Capability Index -----------------------------------
function loadCapabilityIndex() {
  const md = readFileSync(resolve(ROOT, "SKILL.md"), "utf8");
  const rows = md
    .split("\n")
    .filter((l) => l.trim().startsWith("|") && l.includes("references/quittance.md"))
    .map((l) => l.split("|").map((c) => c.trim()).filter(Boolean))
    .map(([need, capability, instructions]) => ({ need, capability, instructions }));
  return rows;
}

// ---- intent router (stands in for the Skill Engine LLM) -----------------------------
function route(intent) {
  const t = intent.toLowerCase();
  if (/\b(balance|how much|funds)\b/.test(t)) return "balance";
  if (/\bdeposit|fund|top ?up\b/.test(t)) return "deposit";
  if (/\bwithdraw|refund\b/.test(t)) return "withdraw";
  if (/\bverify|check (the )?payment|is .* (good|valid)\b/.test(t)) return "verify";
  if (/\bpay|send|settle|redeem\b/.test(t)) return "pay";
  return null;
}

const num = (t) => (t.match(/([0-9]*\.?[0-9]+)\s*(phrs)?/i) || [])[1];
const addr = (t) => (t.match(/0x[0-9a-fA-F]{40}/) || [])[0];
const resourceId = (t) => (t.match(/for\s+([\w:-]+)/i) || [])[1] || `intent-${Date.now()}`;

function toWei(eth) {
  return cast(["to-wei", String(eth), "ether"]);
}
function me() {
  return cast(["wallet", "address", "--private-key", KEY]);
}

// ---- write-op pre-checks (as mandated by SKILL.md) ----------------------------------
function preChecks(label) {
  step("pre-check", `Write Operation Pre-checks for "${label}"`);
  log(`         1. network = ${NET.name} (chainId ${NET.chainId}) via ${RPC}`);
  log(`         2. contract = ${QUIT}`);
  const who = me();
  const gas = cast(["balance", who, "--rpc-url", RPC, "--ether"]);
  log(`         3. signer  = ${who}`);
  log(`         4. gas     = ${gas} PHRS (must be > 0 for a write)`);
  if (Number(gas) <= 0) throw new Error("signer has no PHRS for gas — fund it at the faucet");
  return who;
}

// ---- capabilities (each maps 1:1 to a references/quittance.md section) ----------------
function doBalance(intent) {
  const who = KEY ? me() : addr(intent);
  if (!who) throw new Error("no address to query (provide a key or an address)");
  step(3, "reference: references/quittance.md#reads → balanceOf(address,address)");
  const wei = cast(["call", QUIT, "balanceOf(address,address)(uint256)", who, ZERO, "--rpc-url", RPC]);
  const phrs = cast(["from-wei", wei.split(" ")[0]]);
  step(7, `parsed: Quittance balance of ${who} = ${phrs} PHRS`);
}

function doDeposit(intent) {
  const amount = num(intent);
  if (!amount) throw new Error("could not parse an amount to deposit");
  step(3, "reference: references/quittance.md#deposit-funds → depositNative()");
  preChecks(`deposit ${amount} PHRS`);
  const wei = toWei(amount);
  const out = cast(["send", QUIT, "depositNative()", "--value", wei, "--rpc-url", RPC, "--private-key", KEY, "--legacy"], { send: true });
  step(7, `parsed: deposited ${amount} PHRS — tx ${(out.match(/0x[0-9a-fA-F]{64}/) || ["(see receipt)"])[0]}`);
}

function buildAuth(intent, { forVerify = false } = {}) {
  const amount = num(intent);
  const payee = addr(intent);
  if (!amount || !payee) throw new Error('need an amount and a payee, e.g. "pay 0.01 PHRS to 0x... for invoice-1"');
  const payer = me();
  const wei = toWei(amount);
  const nonce = cast(["keccak", resourceId(intent)]);
  const tuple = `(${payer},${payee},${ZERO},${wei},${nonce},0,0)`;

  step(forVerify ? 3 : 3, "reference: references/quittance.md#build--sign-a-voucher → hashAuthorization");
  const digest = cast(["call", QUIT, `hashAuthorization(${AUTH_TUPLE})(bytes32)`, tuple, "--rpc-url", RPC]);
  step(4, "signing the EIP-712 voucher off-chain (no gas)");
  const sig = cast(["wallet", "sign", "--no-hash", digest, "--private-key", KEY]);
  return { amount, payee, tuple, sig, nonce };
}

function doVerify(intent) {
  const { tuple, sig } = buildAuth(intent, { forVerify: true });
  step(5, "reference: references/quittance.md#verify → verify(auth,sig)");
  const out = cast(["call", QUIT, `verify(${AUTH_TUPLE},bytes)(bool,string)`, tuple, sig, "--rpc-url", RPC]);
  step(7, `parsed: verify → ${out.replace(/\n/g, " ")}`);
}

function doPay(intent) {
  step(3, "reference: references/quittance.md#redeem (full voucher flow)");
  preChecks("pay (deposit must already cover the amount)");
  const { amount, payee, tuple, sig, nonce } = buildAuth(intent);
  step(5, "verify() before settling");
  const v = cast(["call", QUIT, `verify(${AUTH_TUPLE},bytes)(bool,string)`, tuple, sig, "--rpc-url", RPC]);
  log(`         verify → ${v.replace(/\n/g, " ")}`);
  if (!v.toLowerCase().startsWith("true")) throw new Error(`voucher would not settle: ${v}`);
  step(6, "redeem() — settling on-chain (any relayer can submit; funds go to payee)");
  const out = cast(["send", QUIT, `redeem(${AUTH_TUPLE},bytes)`, tuple, sig, "--rpc-url", RPC, "--private-key", KEY, "--legacy"], { send: true });
  const used = cast(["call", QUIT, "nonceUsed(address,bytes32)(bool)", me(), nonce, "--rpc-url", RPC]);
  step(7, `parsed: settled ${amount} PHRS → ${payee}; nonceUsed=${used}; tx ${(out.match(/0x[0-9a-fA-F]{64}/) || ["(see receipt)"])[0]}`);
}

function doWithdraw(intent) {
  const amount = num(intent);
  if (!amount) throw new Error("could not parse an amount to withdraw");
  step(3, "reference: references/quittance.md#withdraw-unspent-balance → withdraw(address,uint256)");
  preChecks(`withdraw ${amount} PHRS`);
  const out = cast(["send", QUIT, "withdraw(address,uint256)", ZERO, toWei(amount), "--rpc-url", RPC, "--private-key", KEY, "--legacy"], { send: true });
  step(7, `parsed: withdrew ${amount} PHRS — tx ${(out.match(/0x[0-9a-fA-F]{64}/) || ["(see receipt)"])[0]}`);
}

// ---- main ---------------------------------------------------------------------------
function main() {
  const intent = process.argv.slice(2).join(" ").trim();
  if (!intent) {
    console.error('Usage: node examples/agent/quittance-agent.mjs "<request>"');
    process.exit(1);
  }

  log(`\x1b[1mUser:\x1b[0m ${intent}\n`);
  step(1, "read SKILL.md — loading the Capability Index");
  const index = loadCapabilityIndex();
  log(`         (${index.length} capabilities available)`);

  step(2, "match intent → capability");
  const cap = route(intent);
  if (!cap) {
    console.error("         no matching capability. Try: balance / deposit / pay / verify / withdraw.");
    process.exit(2);
  }
  log(`         matched: \x1b[33m${cap}\x1b[0m`);

  const handlers = { balance: doBalance, deposit: doDeposit, pay: doPay, verify: doVerify, withdraw: doWithdraw };
  try {
    handlers[cap](intent);
    log(`\n\x1b[32m✓ done\x1b[0m`);
  } catch (e) {
    console.error(`\n\x1b[31m✗ ${e.message}\x1b[0m`);
    process.exit(1);
  }
}

main();
