---
name: quittance
title: Quittance — On-Chain Agent Micropayment Settlement (x402-style)
description: >-
  A credibly-neutral settlement layer for AI-agent payments on Pharos. A payer deposits
  funds (native PHRS or any ERC20 stablecoin), signs off-chain EIP-712 payment vouchers
  (no gas, no API key), and anyone — a relayer or x402 facilitator — settles them on-chain
  to the payee with single-use replay protection. Supports EOA and smart-account (EIP-1271)
  payers. No owner, no admin keys, no protocol fee. The payments backbone Phase-2 Agents
  build on.
network: pharos_atlantic_testnet
chainId: 688689
deployedAddress: "0xd872C6F530c2E1055a522B1978CA99FE65B99F56"
verified: true
version: 0.1.0
license: MIT
---

# Quittance Skill

Quittance is the on-chain core of an [x402](https://www.x402.org)-style payment flow — *sign
off-chain, settle on-chain* — for the Pharos AI Agent economy. It turns "pay another agent /
a paid API per call" into one safe, reusable settlement primitive any Phase-2 Agent can
depend on.

**Flow:** `deposit` (payer funds) → sign an **EIP-712 voucher** off-chain → `verify` (server
pre-check) → `redeem` (anyone relays; payee gets paid). Single-use nonces prevent replay.

- **Live & verified:** [`0xd872C6F530c2E1055a522B1978CA99FE65B99F56`](https://atlantic.pharosscan.xyz/address/0xd872C6F530c2E1055a522B1978CA99FE65B99F56) on Pharos Atlantic Testnet (688689).
- Contract: `src/quittance/Quittance.sol` (mirror in `assets/quittance/Quittance.sol`)
- Deploy script: `script/quittance/DeployQuittance.s.sol`
- Full operation reference: [`references/quittance.md`](references/quittance.md)
- Network config: `assets/networks.json` · Tokens: `assets/tokens.json`
- Off-chain template (viem): `assets/templates/quittance.ts`
- Runnable agent-invocation demo: [`examples/agent/quittance-agent.mjs`](examples/agent/quittance-agent.mjs)

## Prerequisites

- **Foundry** (`cast`, `forge`) installed: `curl -L https://foundry.paradigm.xyz | bash && foundryup`.
- A **funded testnet account** — the signer needs PHRS for gas. Faucet: https://testnet.pharosnetwork.xyz
- The deployed **Quittance address** (above) or your own deploy (see references → "Deploy Quittance").
- Export `PRIVATE_KEY` (testnet only). It is passed explicitly to every write command; Quittance
  never reads it implicitly.

## Network Configuration

Read from [`assets/networks.json`](assets/networks.json). Default target:

| Field | Value |
|-------|-------|
| Network | Pharos Atlantic Testnet |
| chainId | `688689` |
| RPC | `https://atlantic.dplabs-internal.com` |
| Explorer | `https://atlantic.pharosscan.xyz` |
| Native coin | PHRS |

```bash
export RPC=https://atlantic.dplabs-internal.com
export QUIT=0xd872C6F530c2E1055a522B1978CA99FE65B99F56
export ZERO=0x0000000000000000000000000000000000000000
```
The same package also lists **Pharos Testnet (`688688`, `https://testnet.dplabs-internal.com`)**;
deploy there unchanged and swap `--rpc-url` to target it.

## Capability Index

| User Need | Capability | Detailed Instructions |
|-----------|------------|-----------------------|
| "Deploy the payment rail / set up agent payments" | `forge script` deploy | → [references/quittance.md](references/quittance.md#deploy-quittance) |
| "Fund my agent / deposit PHRS or stablecoin to pay with" | `depositNative` / `deposit` | → [references/quittance.md](references/quittance.md#deposit-funds) |
| "Authorize a payment / sign a voucher to pay an agent or API" | `hashAuthorization` + sign | → [references/quittance.md](references/quittance.md#build--sign-a-voucher-off-chain-no-gas) |
| "Check a payment is good before delivering the resource" | `verify` | → [references/quittance.md](references/quittance.md#verify-read-only-x402-check) |
| "Settle / claim a payment / redeem a voucher" | `redeem` | → [references/quittance.md](references/quittance.md#redeem-settle-a-voucher) |
| "Settle many micropayments at once" | `redeemMany` | → [references/quittance.md](references/quittance.md#batch-settlement) |
| "Withdraw my unspent funds" | `withdraw` | → [references/quittance.md](references/quittance.md#withdraw-unspent-balance) |
| "Check balance / has a voucher been used" | `balanceOf` / `nonceUsed` | → [references/quittance.md](references/quittance.md#reads) |
| "Audit / verify the contract on the explorer" | `forge verify-contract` | → [references/quittance.md](references/quittance.md#verify-the-contract-on-pharosscan-optional) |

## Write Operation Pre-checks

Before executing any **write** (`deposit`, `withdraw`, `redeem`, `redeemMany`), the agent MUST:

1. **Confirm the network** — `cast chain-id --rpc-url $RPC` equals the `chainId` in `networks.json`.
2. **Confirm the contract** — `$QUIT` is the intended Quittance address (and is verified on the explorer).
3. **Confirm the signer & gas** — `cast balance $(cast wallet address --private-key $PRIVATE_KEY) --rpc-url $RPC` is `> 0`.
4. **Confirm the parameters** — echo the human-readable amount, token, payee and nonce back to the
   user and ensure, for `redeem`, that `verify(...)` returns `(true, "ok")` first.

## General Error Handling

- Reverts surface as human-readable strings prefixed `Quittance: ...` — read them directly; the
  per-operation **Error Handling** tables in [`references/quittance.md`](references/quittance.md) map
  each one to a cause and a suggested action.
- `Quittance: nonce already used` → the voucher was already redeemed; issue a new voucher with a
  fresh `nonce`.
- `Quittance: insufficient payer balance` → the payer must `deposit` more before the voucher settles.
- `Quittance: invalid signature` → the tuple was changed after signing, or the wrong key signed;
  re-`hashAuthorization` the exact tuple and re-sign with the payer key.
- RPC/network errors → retry; confirm the RPC URL and chain id from `networks.json`.

## Security Reminders

- **Never paste a mainnet/real private key.** Use a dedicated **testnet** key; it is only ever
  passed explicitly to `cast`/`forge`.
- Quittance has **no owner, no admin keys, no protocol fee** — nothing privileged to abuse.
- Funds are debited from the payer's balance **before** payout (checks-effects-interactions) under
  a reentrancy guard; ECDSA recovery rejects malleable signatures; smart-account payers use EIP-1271.
- A `nonce` is **single-use per payer** — treat it as the payment's idempotency key and never reuse it.
- Always `verify` before delivering a paid resource; confirm `nonceUsed` after `redeem`.

## Quick facts for the agent

- Voucher tuple: `(payer, payee, token, amount, nonce, validAfter, validBefore)`.
- `token = 0x0000000000000000000000000000000000000000` → native PHRS.
- `validBefore = 0` → never expires; `validAfter = 0` → valid immediately.
- Amounts are in wei: `cast to-wei <n> ether`; nonces: `cast keccak "<resourceId>"`.
- Settlement is gasless for the payer: any relayer/facilitator can submit `redeem`.
