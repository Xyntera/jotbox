# Skill Reference: `quittance` — Agent Micropayment Settlement (x402-style)

On-chain settlement for agent payments on Pharos. A **payer** deposits funds (native PHRS
or any ERC20 stablecoin) into Quittance, signs **off-chain EIP-712 vouchers** authorizing a
**payee** to receive a fixed amount for a resource, and anyone (a relayer / x402 facilitator)
calls `redeem` to settle it on-chain. `verify` is the matching read-only pre-check.

**Contract:** `Quittance` · **Skill id:** `quittance` · No owner, no admin keys, no protocol fee.

## Environment

```bash
# Live deployment (Pharos Atlantic Testnet, chain id 688689):
export RPC=https://atlantic.dplabs-internal.com
export QUIT=0xd872C6F530c2E1055a522B1978CA99FE65B99F56   # verified Quittance
export PRIVATE_KEY=0xYOUR_TESTNET_KEY                     # must hold PHRS for gas
export ME=$(cast wallet address --private-key $PRIVATE_KEY)
export ZERO=0x0000000000000000000000000000000000000000   # native PHRS sentinel

# The voucher tuple type used by hashAuthorization / verify / redeem:
#   (address payer,address payee,address token,uint256 amount,bytes32 nonce,uint256 validAfter,uint256 validBefore)
```

> **Agent Guidelines (global):** A voucher is single-use per `(payer, nonce)`. Use a fresh
> `nonce` per payment (e.g. `cast keccak "<resourceId>:<counter>"`). `token = ZERO` means
> native PHRS. `validBefore = 0` means no expiry. Always call `verify` before delivering a
> paid resource, and confirm `nonceUsed` / balances after `redeem`.

---

## Deploy Quittance

### Overview
Deploy once per network; everyone shares the same settlement contract.

### Command Template
```bash
forge script script/quittance/DeployQuittance.s.sol \
  --rpc-url $RPC --private-key $PRIVATE_KEY --broadcast
```

### Output Parsing
Logs `Quittance deployed at: 0x...` and the `DOMAIN_SEPARATOR`. Save the address as `$QUIT`.

> **Agent Guidelines:** 1) Fund `$PRIVATE_KEY` with PHRS. 2) Run the script. 3) Capture
> `$QUIT`. 4) Verify the source (last section) so payers can audit before depositing.

---

## Deposit funds

### Overview
A payer must hold a Quittance balance before vouchers can settle. Deposit native or ERC20.

### Command Template
```bash
# native PHRS
cast send $QUIT "depositNative()" --value $(cast to-wei 1 ether) \
  --rpc-url $RPC --private-key $PRIVATE_KEY

# ERC20 (approve first)
cast send $TOKEN "approve(address,uint256)" $QUIT $(cast to-wei 100 ether) \
  --rpc-url $RPC --private-key $PRIVATE_KEY
cast send $QUIT "deposit(address,uint256)" $TOKEN $(cast to-wei 100 ether) \
  --rpc-url $RPC --private-key $PRIVATE_KEY
```

### Parameters
| Name   | Type      | Required | Description |
|--------|-----------|----------|-------------|
| token  | `address` | yes (ERC20) | ERC20 token address. Use `depositNative` for PHRS. |
| amount | `uint256` | yes      | Amount in base units. Must be `> 0` (and `--value` for native). |

### Output Parsing
Emits `Deposited(payer, token, amount)`. Confirm with
`cast call $QUIT "balanceOf(address,address)(uint256)" $ME $TOKEN --rpc-url $RPC`.

### Error Handling
| Error Signature | Cause | Suggested action |
|---------------|-------|------------------|
| `Quittance: use depositNative for native` | called `deposit` with `token = 0x0` | Use `depositNative`. |
| `Quittance: ERC20 transferFrom failed` | missing approval / balance | Approve and fund first. |

---

## Build & sign a voucher (off-chain, no gas)

### Overview
The payer signs an EIP-712 `PaymentAuthorization`. The simplest robust flow is to let the
contract compute the digest, then sign that digest as a raw hash.

### Command Template
```bash
PAYER=$ME
PAYEE=0xRECIPIENT
AMT=$(cast to-wei 0.01 ether)
NONCE=$(cast keccak "invoice-42")          # unique per payment
TUPLE="($PAYER,$PAYEE,$ZERO,$AMT,$NONCE,0,0)"

# 1) digest from the contract (chain/domain-bound)
DIGEST=$(cast call $QUIT \
  "hashAuthorization((address,address,address,uint256,bytes32,uint256,uint256))(bytes32)" \
  "$TUPLE" --rpc-url $RPC)

# 2) sign it (raw 32-byte hash) — produces a 65-byte signature
SIG=$(cast wallet sign --no-hash "$DIGEST" --private-key $PRIVATE_KEY)
```

### Parameters (voucher fields)
| Field       | Type      | Description |
|-------------|-----------|-------------|
| payer       | `address` | Who pays; must have a Quittance balance and sign the voucher. |
| payee       | `address` | Who receives the funds. |
| token       | `address` | `ZERO` for native PHRS, else ERC20. |
| amount      | `uint256` | Amount to settle (base units). |
| nonce       | `bytes32` | Unique per payment; doubles as resource/idempotency id. |
| validAfter  | `uint256` | Earliest redeem time (`0` = now). |
| validBefore | `uint256` | Expiry (`0` = never). |

> **Agent Guidelines:** Smart-account (EIP-1271) payers sign with their owner key; Quittance
> calls `isValidSignature` on the payer contract automatically — same `redeem` call.

---

## verify (read-only x402 check)

### Command Template
```bash
cast call $QUIT \
  "verify((address,address,address,uint256,bytes32,uint256,uint256),bytes)(bool,string)" \
  "$TUPLE" "$SIG" --rpc-url $RPC
```

### Output Parsing
Returns `(bool ok, string reason)`. `ok = true, reason = "ok"` means `redeem` will succeed.
Otherwise `reason` is one of: `amount must be greater than zero`, `authorization not yet
valid`, `authorization expired`, `nonce already used`, `invalid signature`, `insufficient
payer balance`.

> **Agent Guidelines:** A server/facilitator should call `verify` BEFORE delivering the
> paid resource, then `redeem` (or hand the voucher to a relayer) to actually settle.

---

## redeem (settle a voucher)

### Overview
Settles one voucher. Callable by **anyone** (relayer / payee / facilitator); funds always go
to `payee`. The payer pays no gas for settlement.

### Command Template
```bash
cast send $QUIT \
  "redeem((address,address,address,uint256,bytes32,uint256,uint256),bytes)" \
  "$TUPLE" "$SIG" --rpc-url $RPC --private-key $RELAYER_KEY
```

### Output Parsing
Emits `PaymentSettled(payer, payee, token, amount, nonce)`. Confirm with
`cast call $QUIT "nonceUsed(address,bytes32)(bool)" $PAYER $NONCE --rpc-url $RPC`.

### Error Handling
| Error Signature | Cause | Suggested action |
|---------------|-------|------------------|
| `Quittance: nonce already used` | voucher already redeemed | Issue a new voucher with a fresh nonce. |
| `Quittance: authorization expired` | past `validBefore` | Re-issue with a later expiry. |
| `Quittance: authorization not yet valid` | before `validAfter` | Wait until `validAfter`. |
| `Quittance: invalid signature` | wrong signer or tampered fields | Re-sign the exact tuple with the payer key. |
| `Quittance: insufficient payer balance` | payer underfunded | Payer must `deposit` more. |

> **Agent Guidelines:** 1) `verify` first. 2) `redeem`. 3) Check `nonceUsed == true` and the
> payee balance increased.

### Batch settlement
```bash
cast send $QUIT \
  "redeemMany((address,address,address,uint256,bytes32,uint256,uint256)[],bytes[])" \
  "[$TUPLE1,$TUPLE2]" "[$SIG1,$SIG2]" --rpc-url $RPC --private-key $RELAYER_KEY
```
Settles many vouchers in one tx — ideal for high-throughput agent micropayments on Pharos.

---

## Withdraw unspent balance

```bash
cast send $QUIT "withdraw(address,uint256)" $ZERO $(cast to-wei 0.5 ether) \
  --rpc-url $RPC --private-key $PRIVATE_KEY
```
Refunds your own unspent Quittance balance. Emits `Withdrawn(payer, token, amount)`.

| Error Signature | Cause | Suggested action |
|---------------|-------|------------------|
| `Quittance: insufficient balance` | withdrawing more than deposited-minus-spent | Lower the amount. |

---

## Reads

```bash
cast call $QUIT "balanceOf(address,address)(uint256)" $PAYER $TOKEN --rpc-url $RPC
cast call $QUIT "nonceUsed(address,bytes32)(bool)"     $PAYER $NONCE --rpc-url $RPC
cast call $QUIT "DOMAIN_SEPARATOR()(bytes32)"          --rpc-url $RPC
```

---

## Verify the contract on PharosScan (optional)

```bash
forge verify-contract $QUIT src/quittance/Quittance.sol:Quittance \
  --verifier blockscout \
  --verifier-url https://api.socialscan.io/pharos-atlantic-testnet/v1/explorer/command_api/contract \
  --chain-id 688689
```

> Source verification lets any payer audit Quittance before depositing — critical for a
> contract that custodies funds. The live deployment above is already verified.
