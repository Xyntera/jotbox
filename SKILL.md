---
name: payrail
title: PayRail — On-Chain Agent Micropayment Settlement (x402-style)
description: >-
  A credibly-neutral settlement layer for AI-agent payments on Pharos. A payer deposits
  funds (native PHRS or any ERC20 stablecoin), signs off-chain EIP-712 payment vouchers
  (no gas, no API key), and anyone — a relayer or x402 facilitator — settles them on-chain
  to the payee with single-use replay protection. Supports EOA and smart-account (EIP-1271)
  payers. No owner, no admin keys, no protocol fee. The payments backbone Phase-2 Agents
  build on.
network: pharos_atlantic_testnet
chainId: 688689
deployedAddress: "0xdfDf119964C7858905FbE7175Ff32fdD509dEc50"
verified: true
version: 0.1.0
license: MIT
---

# PayRail Skill

PayRail is the on-chain core of an [x402](https://www.x402.org)-style payment flow — *sign
off-chain, settle on-chain* — built for the Pharos AI Agent economy. It turns "pay another
agent / a paid API per call" into a single, safe, reusable settlement primitive that any
Phase-2 Agent can depend on instead of reinventing payments.

**Flow:** `deposit` (payer funds) → sign an **EIP-712 voucher** off-chain → `verify` (server
pre-check) → `redeem` (anyone relays; payee gets paid). Single-use nonces prevent replay.

- **Live & verified:** [`0xdfDf119964C7858905FbE7175Ff32fdD509dEc50`](https://atlantic.pharosscan.xyz/address/0xdfDf119964C7858905FbE7175Ff32fdD509dEc50) on Pharos Atlantic Testnet (688689).
- Contract: `src/payrail/PayRail.sol` (mirror in `assets/payrail/PayRail.sol`)
- Deploy script: `script/payrail/DeployPayRail.s.sol`
- Full operation reference: [`references/payrail.md`](references/payrail.md)
- Network config: `assets/networks.json` · Tokens: `assets/tokens.json`
- Off-chain template (viem): `assets/templates/payrail.ts`

## Capability Index

| User Need | Capability | Instructions |
|-----------|------------|--------------|
| "Deploy the payment rail / set up agent payments" | `forge script` deploy | → [references/payrail.md](references/payrail.md#deploy-payrail) |
| "Fund my agent / deposit PHRS or stablecoin to pay with" | `depositNative` / `deposit` | → [references/payrail.md](references/payrail.md#deposit-funds) |
| "Authorize a payment / sign a voucher to pay an agent or API" | `hashAuthorization` + sign | → [references/payrail.md](references/payrail.md#build--sign-a-voucher-off-chain-no-gas) |
| "Check a payment is good before delivering the resource" | `verify` | → [references/payrail.md](references/payrail.md#verify-read-only-x402-check) |
| "Settle / claim a payment / redeem a voucher" | `redeem` | → [references/payrail.md](references/payrail.md#redeem-settle-a-voucher) |
| "Settle many micropayments at once" | `redeemMany` | → [references/payrail.md](references/payrail.md#batch-settlement) |
| "Withdraw my unspent funds" | `withdraw` | → [references/payrail.md](references/payrail.md#withdraw-unspent-balance) |
| "Check balance / has a voucher been used" | `balanceOf` / `nonceUsed` | → [references/payrail.md](references/payrail.md#reads) |
| "Audit / verify the contract on the explorer" | `forge verify-contract` | → [references/payrail.md](references/payrail.md#verify-the-contract-on-pharosscan-optional) |

## Quick facts for the agent

- Voucher tuple: `(payer, payee, token, amount, nonce, validAfter, validBefore)`.
- `token = 0x0000000000000000000000000000000000000000` → native PHRS.
- `nonce` is single-use per payer — use a fresh one per payment (`cast keccak "<id>"`).
- `validBefore = 0` → never expires; `validAfter = 0` → valid immediately.
- Settlement is gasless for the payer: any relayer/facilitator can submit `redeem`.
- EOA payers sign with ECDSA; smart-account payers are checked via EIP-1271 automatically.
- Always `verify` before delivering a paid resource; confirm `nonceUsed` after `redeem`.
- Safety: no admin keys, reentrancy-guarded, checks-effects-interactions, malleability-
  resistant ECDSA, non-standard-ERC20 tolerant.
