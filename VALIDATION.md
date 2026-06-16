# Quittance — Skill Engine Validation

This document validates the Quittance skill against the
[Pharos Skill Engine guide](https://docs.pharos.xyz/tooling-and-infrastructure/pharos-skill-engine-guide)
— both the required file format and the publishing checklist — and records live, on-chain
evidence that an agent can invoke it end-to-end.

## 1. Format compliance

### Folder layout (matches the Skill Engine package)
```
SKILL.md                       ✓ agent entry point + Capability Index
assets/networks.json           ✓ RPC URLs / chain ids / explorers
assets/tokens.json             ✓ token registry
assets/quittance/Quittance.sol     ✓ contract under assets/<skill>/
assets/templates/quittance.ts    ✓ off-chain interaction template
references/quittance.md          ✓ references/<skill>.md
src/quittance/Quittance.sol        ✓ source
script/quittance/DeployQuittance.s.sol
test/Quittance.t.sol
examples/agent/quittance-agent.mjs   (runnable invocation demo)
```

### SKILL.md — required sections (per the guide)
| Required section | Present |
|------------------|---------|
| Prerequisites | ✓ |
| Network Configuration | ✓ |
| Capability Index (`User Need | Capability | Detailed Instructions`) | ✓ (9 rows) |
| Write Operation Pre-checks | ✓ (4 checks) |
| General Error Handling | ✓ |
| Security Reminders | ✓ |

### references/quittance.md — required per-operation sections
Every operation documents: **Overview · Command Template · Parameters · Output Parsing ·
Error Handling (`Error Signature | Cause | Suggested Action`) · Agent Guidelines** — for
`deploy, deposit, sign-voucher, verify, redeem, redeemMany, withdraw, reads, verify-source`.

## 2. Publishing checklist

| Checklist item | Status |
|----------------|--------|
| Contract compiles (`forge build`) | ✓ |
| Test suite passes (`forge test`) | ✓ 14 tests incl. EIP-1271, replay/expiry/tamper, fuzz |
| Deployed on Pharos testnet (confirmed tx hash) | ✓ `0xd872C6F530c2E1055a522B1978CA99FE65B99F56` |
| Contract verified on Pharos Scan | ✓ [verified](https://atlantic.pharosscan.xyz/address/0xd872C6F530c2E1055a522B1978CA99FE65B99F56) |
| Reference file complete for every public function | ✓ |
| Capability Index updated with natural-language phrasings | ✓ |
| Revert strings match between contract and Error Handling tables | ✓ |

## 3. Live agent-invocation evidence

Run faithfully through the Skill Engine runtime flow (read `SKILL.md` → match Capability
Index → read `references/quittance.md` → read `networks.json` → run pre-checks → execute
`cast` → parse output) by [`examples/agent/quittance-agent.mjs`](examples/agent/quittance-agent.mjs)
against the live deployment on Pharos Atlantic Testnet (688689):

| Agent request (natural language) | On-chain result | Tx |
|----------------------------------|-----------------|----|
| "what is my Quittance balance?" | read `balanceOf` → parsed PHRS balance | (call) |
| "deposit 0.03 PHRS into Quittance" | `depositNative()` settled | `0x696ef5a156e998d09f5ddcb0cf8c65bac5cb8182a7a014fd64cba89c48551c64` |
| "pay 0.004 PHRS to 0x…C0ffee00 for invoice-…" | off-chain EIP-712 sign → `verify → true "ok"` → `redeem` → payee paid, `nonceUsed=true` | `0x8ce98165dbe805dbdda0801aa936814595808ee804402fe85b7d83c571301600` |
| Deploy | `Quittance` constructor | `0xc9a52a8d47d7b3242994e628981d8fd36e45c5ddeb0d401a8b0326b3f709585d` |

Reproduce:
```bash
export PRIVATE_KEY=0xYOUR_TESTNET_KEY
node examples/agent/quittance-agent.mjs "deposit 0.03 PHRS into Quittance"
node examples/agent/quittance-agent.mjs "pay 0.004 PHRS to 0x00000000000000000000000000000000C0ffee00 for invoice-1"
```

## 4. Security self-review (CertiK Skill Scanner is the official standard)

- **No privileged roles** — no owner, admin, pause, upgrade, or fee setters; nothing to abuse or rug.
- **Reentrancy** — `nonReentrant` on every fund-moving entry point; checks-effects-interactions
  (nonce burned + balance debited *before* payout).
- **Signature safety** — EIP-712 domain bound to `chainId` + contract address; ECDSA rejects
  high-`s` (malleable) signatures and bad `v`; EIP-1271 for smart-account payers.
- **Replay** — single-use `nonceUsed[payer][nonce]`; timing bounded by `validAfter`/`validBefore`.
- **Token safety** — low-level transfer/transferFrom tolerant of non-standard (no-return) ERC20s;
  return data checked.
- **Funds isolation** — each payer can only ever spend/withdraw their own deposited balance.
