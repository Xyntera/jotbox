# Quittance — On-Chain Agent Micropayment Settlement for Pharos

> A submission to the **Pharos Skill-to-Agent Dual Cascade Hackathon — Phase 1 (Skill Hackathon)**.
> A reusable [Pharos Skill Engine](https://docs.pharos.xyz/tooling-and-infrastructure/pharos-skill-engine-guide)
> module that gives AI agents a **credibly-neutral settlement layer** for payments — the
> on-chain core of an [x402](https://www.x402.org)-style *"sign off-chain, settle on-chain"* flow.

Quittance turns *"pay another agent / a paid API, per call"* into one safe primitive. A **payer**
deposits funds (native **PHRS** or any **ERC20** stablecoin), signs **off-chain EIP-712 payment
vouchers** — no gas, no API key — and **anyone** (a relayer or x402 facilitator) settles them
on-chain to the **payee**, with single-use replay protection. It is the **payments backbone**
that Phase-2 Agents depend on instead of reinventing settlement.

## Why this skill wins

The agent economy rests on three backbones — identity, **payments**, and safety. Quittance owns
payments, the one Pharos was literally built for ("on-chain payments for the AI Agent economy").

| Judging criterion | How Quittance delivers |
|-------------------|----------------------|
| **Alignment with the Pharos vision** | Pharos = on-chain payments + RealFi for agents. Quittance *is* the settlement rail. |
| **Originality** | Implements the [x402](https://www.x402.org) thesis (Coinbase/Visa/Google; 119M+ txs) natively on Pharos — vouchers + on-chain settlement — not a token/airdrop clone. |
| **Practical use case for agents** | Gasless-for-payer, per-call micropayments between agents and to paid APIs; relayer-settled. |
| **Reusability & composability** | A dependency, not an app: any Agent that pays or gets paid uses `deposit → sign → verify → redeem`. |
| **Technical quality** | EIP-712 + EIP-1271 (smart-account agents), malleability-resistant ECDSA, single-use nonces, reentrancy-guarded, **no admin keys**, non-standard-ERC20 safe. 14 passing tests incl. fuzzing. |
| **Security (CertiK Skill Scanner is the official standard)** | Zero privileged functions = zero admin-key risk; checks-effects-interactions on every fund path. |
| **Docs & UX** | Full Skill Engine integration: `SKILL.md` capability index + a complete `references/quittance.md` with `cast`/`forge` templates, parameter & error tables, and agent guidelines. |

## How it fits the Pharos Skill Engine

```
SKILL.md                       # capability index (agent entry point)
references/quittance.md          # per-operation reference (commands, params, errors, guidelines)
src/quittance/Quittance.sol        # the skill contract
assets/quittance/Quittance.sol     #   mirror, per Skill Engine convention
assets/networks.json           # Pharos testnet RPC / chain id / explorer
assets/tokens.json             # token registry (PHRS / stablecoin)
assets/templates/quittance.ts    # off-chain interaction template (viem)
script/quittance/DeployQuittance.s.sol
test/Quittance.t.sol             # 14 tests
examples/agent/quittance-agent.mjs   # runnable agent-invocation harness
VALIDATION.md                  # Skill Engine compliance + live evidence
```

## Validation & live agent invocation

`VALIDATION.md` checks Quittance against the Skill Engine format and publishing checklist.
`examples/agent/quittance-agent.mjs` then **proves the skill is agent-invocable**: it follows the
exact Skill Engine runtime flow — read `SKILL.md` → match the Capability Index → read
`references/quittance.md` → read `networks.json` → run pre-checks → execute `cast` → parse output —
and was run **live** against the deployment:

```text
User: pay 0.003 PHRS to 0x…C0ffee00 for invoice-quit-42
[agent 1] read SKILL.md — Capability Index (9 capabilities)
[agent 2] match intent → capability: pay
[agent 3] reference: references/quittance.md#redeem (full voucher flow)
[agent 4] signing the EIP-712 voucher off-chain (no gas)
[agent 5] verify() → true "ok"
[agent 6] redeem() — settling on-chain
[agent 7] parsed: settled 0.003 PHRS → 0x…C0ffee00; nonceUsed=true; tx 0x8ce9…1600
✓ done
```

```bash
export PRIVATE_KEY=0xYOUR_TESTNET_KEY
node examples/agent/quittance-agent.mjs "deposit 0.03 PHRS into Quittance"
node examples/agent/quittance-agent.mjs "pay 0.004 PHRS to 0x00000000000000000000000000000000C0ffee00 for invoice-1"
```

## Payment flow

```
            off-chain (no gas)                         on-chain
 payer ──deposit──► Quittance balance
 payer ──sign EIP-712 voucher (payee, token, amount, nonce, expiry)──► voucher+signature
 server ──verify(voucher)──► ok? deliver the paid resource
 relayer/payee ──redeem(voucher, sig)──► Quittance checks sig+expiry+nonce+balance
                                          └─► settles amount to payee, burns the nonce
```

## Live deployment

`Quittance` is **deployed and source-verified** on **Pharos Atlantic Testnet** (the testnet the
Skill Engine guide targets, `RPC=https://atlantic.dplabs-internal.com`).

| | |
|---|---|
| Network | Pharos Atlantic Testnet |
| Chain ID | `688689` |
| **Quittance** | [`0xd872C6F530c2E1055a522B1978CA99FE65B99F56`](https://atlantic.pharosscan.xyz/address/0xd872C6F530c2E1055a522B1978CA99FE65B99F56) |
| Deploy tx | [`0xc9a52a8d47d7b3242994e628981d8fd36e45c5ddeb0d401a8b0326b3f709585d`](https://atlantic.pharosscan.xyz/tx/0xc9a52a8d47d7b3242994e628981d8fd36e45c5ddeb0d401a8b0326b3f709585d) |
| Source verified | ✅ yes |
| Explorer | `https://atlantic.pharosscan.xyz` |
| Native coin | PHRS |

**Exercised live, end-to-end:** the payer deposited PHRS, signed an EIP-712 voucher off-chain,
`verify()` returned `(true, "ok")`, a **third-party relayer** settled it (payee received the
exact amount, payer's balance decremented), and a re-`verify()` then returned
`(false, "nonce already used")` — proving replay protection. All visible on the contract's
explorer page.

> The same artifact deploys unchanged to **Pharos Testnet (chain 688688)** — both networks are
> in `assets/networks.json`; just point `--rpc-url` at the other RPC.

## Quickstart

```bash
# 1. Install Foundry
curl -L https://foundry.paradigm.xyz | bash && foundryup

# 2. Build & test
forge install foundry-rs/forge-std   # if lib/ is empty after clone
forge build
forge test -vvv

# 3. Configure
cp .env.example .env                 # edit .env with a TESTNET key
export $(grep -v '^#' .env | xargs)

# 4. Deploy to Pharos Atlantic Testnet
forge script script/quittance/DeployQuittance.s.sol \
  --rpc-url https://atlantic.dplabs-internal.com --private-key $PRIVATE_KEY --broadcast
```

Get testnet PHRS from the [Pharos faucet](https://testnet.pharosnetwork.xyz), then follow
[`references/quittance.md`](references/quittance.md) to deposit, sign, verify, and redeem.

## Security notes

- **No owner, no admin keys, no protocol fee** — nothing privileged to abuse or rug.
- Funds custodied per-payer; settlement debits the payer's balance **before** paying out
  (checks-effects-interactions) under a `nonReentrant` guard.
- Single-use nonces per payer prevent voucher replay; `validAfter`/`validBefore` bound timing.
- ECDSA recovery rejects high-`s` (malleable) signatures and bad `v`; EIP-1271 supports
  smart-account agents.
- Low-level token calls tolerate non-standard ERC20s (no-return tokens like USDT).
- ⚠️ Never commit a real private key. Use a dedicated **testnet** key; `.env` is gitignored.

## License

MIT
