/**
 * PayRail interaction template (viem).
 *
 * Shows the full x402-style flow an off-chain agent runs against PayRail on Pharos:
 *   deposit -> sign an EIP-712 voucher (no gas) -> verify -> redeem.
 * Install: `npm i viem`.
 *
 * Env: PAYER_PK (testnet), RELAYER_PK (testnet), PAYRAIL (deployed address), PAYEE.
 */
import {
  createPublicClient,
  createWalletClient,
  http,
  parseEther,
  keccak256,
  toHex,
  zeroAddress,
  defineChain,
  type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

export const pharosAtlantic = defineChain({
  id: 688689,
  name: "Pharos Atlantic Testnet",
  nativeCurrency: { name: "Pharos", symbol: "PHRS", decimals: 18 },
  rpcUrls: { default: { http: ["https://atlantic.dplabs-internal.com"] } },
  blockExplorers: { default: { name: "PharosScan", url: "https://atlantic.pharosscan.xyz" } },
});

// EIP-712 typed-data definition for a PayRail voucher.
export const payrailTypes = {
  PaymentAuthorization: [
    { name: "payer", type: "address" },
    { name: "payee", type: "address" },
    { name: "token", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "nonce", type: "bytes32" },
    { name: "validAfter", type: "uint256" },
    { name: "validBefore", type: "uint256" },
  ],
} as const;

export const payrailAbi = [
  { type: "function", name: "depositNative", stateMutability: "payable", inputs: [], outputs: [] },
  {
    type: "function",
    name: "verify",
    stateMutability: "view",
    inputs: [
      {
        name: "auth",
        type: "tuple",
        components: payrailTypes.PaymentAuthorization,
      },
      { name: "signature", type: "bytes" },
    ],
    outputs: [
      { name: "ok", type: "bool" },
      { name: "reason", type: "string" },
    ],
  },
  {
    type: "function",
    name: "redeem",
    stateMutability: "nonpayable",
    inputs: [
      { name: "auth", type: "tuple", components: payrailTypes.PaymentAuthorization },
      { name: "signature", type: "bytes" },
    ],
    outputs: [],
  },
] as const;

async function main() {
  const payrail = process.env.PAYRAIL as Address;
  const payee = process.env.PAYEE as Address;
  const payer = privateKeyToAccount(process.env.PAYER_PK as `0x${string}`);
  const relayer = privateKeyToAccount(process.env.RELAYER_PK as `0x${string}`);

  const pub = createPublicClient({ chain: pharosAtlantic, transport: http() });
  const payerWallet = createWalletClient({ account: payer, chain: pharosAtlantic, transport: http() });
  const relayerWallet = createWalletClient({ account: relayer, chain: pharosAtlantic, transport: http() });

  // 1) payer deposits 1 PHRS
  await payerWallet.writeContract({
    address: payrail,
    abi: payrailAbi,
    functionName: "depositNative",
    value: parseEther("1"),
  });

  // 2) payer signs a voucher off-chain (no gas) — EIP-712 typed data
  const auth = {
    payer: payer.address,
    payee,
    token: zeroAddress, // native PHRS
    amount: parseEther("0.01"),
    nonce: keccak256(toHex(`invoice-${Date.now()}`)),
    validAfter: 0n,
    validBefore: 0n,
  } as const;

  const signature = await payerWallet.signTypedData({
    domain: { name: "PayRail", version: "1", chainId: pharosAtlantic.id, verifyingContract: payrail },
    types: payrailTypes,
    primaryType: "PaymentAuthorization",
    message: auth,
  });

  // 3) a server verifies before delivering the paid resource
  const [ok, reason] = await pub.readContract({
    address: payrail,
    abi: payrailAbi,
    functionName: "verify",
    args: [auth, signature],
  });
  console.log("verify ->", ok, reason);

  // 4) any relayer settles it on-chain; the payer pays no gas
  if (ok) {
    const hash = await relayerWallet.writeContract({
      address: payrail,
      abi: payrailAbi,
      functionName: "redeem",
      args: [auth, signature],
    });
    console.log("settled in tx", hash);
  }
}

if (require.main === module) {
  main().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}
