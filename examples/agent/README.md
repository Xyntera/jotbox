# Quittance — Agent Invocation Demo

A runnable harness showing an AI agent invoking the Quittance skill **exactly the way the
Pharos Skill Engine prescribes**: read `SKILL.md` → match the natural-language intent to a
Capability Index row → read `references/quittance.md` → read `assets/networks.json` → run the
Write Operation Pre-checks → execute the `cast` command → parse the output.

The intent→capability matcher is a small deterministic router that **stands in for the Skill
Engine's LLM** (which performs this step by reading `SKILL.md`), so the entire flow can be run
and tested end-to-end on-chain.

## Run

```bash
# from the repo root
curl -L https://foundry.paradigm.xyz | bash && foundryup   # if cast isn't installed
export PRIVATE_KEY=0xYOUR_TESTNET_KEY                       # testnet only; needs PHRS for gas
# optional overrides (defaults target the live Atlantic deployment):
# export RPC=https://atlantic.dplabs-internal.com
# export QUIT=0xd872C6F530c2E1055a522B1978CA99FE65B99F56

node examples/agent/quittance-agent.mjs "what is my Quittance balance?"
node examples/agent/quittance-agent.mjs "deposit 0.03 PHRS into Quittance"
node examples/agent/quittance-agent.mjs "pay 0.004 PHRS to 0x00000000000000000000000000000000C0ffee00 for invoice-1"
node examples/agent/quittance-agent.mjs "withdraw 0.01 PHRS from Quittance"
```

## Supported intents

| Say something like… | Capability | Skill reference |
|---------------------|-----------|-----------------|
| "what's my Quittance balance" | `balanceOf` | `references/quittance.md#reads` |
| "deposit 0.03 PHRS" | `depositNative` | `references/quittance.md#deposit-funds` |
| "pay 0.004 PHRS to 0x… for invoice-7" | sign + `verify` + `redeem` | `references/quittance.md#redeem-settle-a-voucher` |
| "verify a payment of 0.004 PHRS to 0x… for invoice-7" | `verify` | `references/quittance.md#verify-read-only-x402-check` |
| "withdraw 0.01 PHRS" | `withdraw` | `references/quittance.md#withdraw-unspent-balance` |

The `pay` flow performs the full x402-style sequence: build the EIP-712 voucher, sign it
off-chain (no gas), `verify` it, then `redeem` it on-chain so the payee is paid.

> This demo is also the seed for a Phase-2 Agent: swap the deterministic router for an LLM and
> Quittance becomes that agent's payment rail.
