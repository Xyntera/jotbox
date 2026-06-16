// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal ERC20 interface for stablecoin deposits/settlement (e.g. USDC/PROS).
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice EIP-1271 magic value interface so smart-account agents can authorize payments.
interface IERC1271 {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
}

/**
 * @title Quittance
 * @notice An on-chain settlement layer for agent micropayments — the credibly-neutral core
 *         of an x402-style "sign off-chain, settle on-chain" payment flow for the Pharos AI
 *         Agent economy.
 *
 *         A payer deposits funds (native PHRS or any ERC20 stablecoin) into Quittance, then
 *         signs off-chain EIP-712 *payment vouchers* — no gas, no API key — authorizing a
 *         payee to receive a fixed amount for a specific resource (encoded in the voucher
 *         nonce). Anyone (a relayer / x402 facilitator) submits the voucher via `redeem`;
 *         Quittance verifies the signature, validity window, single-use nonce and balance,
 *         then settles to the payee. `verify` is the matching read-only check a server runs
 *         before delivering the paid resource (x402's "verify" step).
 *
 *         Design goals (this is a reusable, composable Skill, not an app):
 *           - Trustless: NO owner, NO admin keys, NO protocol fee. Nothing privileged to abuse.
 *           - Account-abstraction ready: EOAs (ECDSA) and smart-account agents (EIP-1271).
 *           - Safe: reentrancy guard, checks-effects-interactions, malleability-resistant
 *             ECDSA, single-use nonces, non-standard-ERC20 tolerant transfers.
 *           - Agent-friendly: `verify` returns a human-readable reason; rich events; helpers
 *             (`DOMAIN_SEPARATOR`, `hashAuthorization`) so agents can build/verify vouchers.
 */
contract Quittance {
    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    /// @dev A single-use, signed authorization to pay `payee` `amount` of `token` from `payer`.
    struct PaymentAuthorization {
        address payer; // who funds the payment (must have a Quittance balance)
        address payee; // who receives the funds
        address token; // address(0) == native PHRS, else ERC20 token
        uint256 amount; // amount to settle (must be > 0)
        bytes32 nonce; // unique per (payer, voucher); doubles as a resource/idempotency id
        uint256 validAfter; // not redeemable before this timestamp (0 == immediately)
        uint256 validBefore; // not redeemable after this timestamp (0 == never expires)
    }

    // ---------------------------------------------------------------------
    // Constants / immutables
    // ---------------------------------------------------------------------

    bytes32 private constant _PAYMENT_TYPEHASH = keccak256(
        "PaymentAuthorization(address payer,address payee,address token,uint256 amount,bytes32 nonce,uint256 validAfter,uint256 validBefore)"
    );
    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes4 private constant _ERC1271_MAGIC = 0x1626ba7e;
    /// @dev secp256k1n / 2, for low-`s` (non-malleable) signatures.
    uint256 private constant _HALF_N = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    /// @notice Deposited, withdrawable balance: payer => token => amount.
    mapping(address => mapping(address => uint256)) public balanceOf;

    /// @notice Replay protection: payer => voucher nonce => spent.
    mapping(address => mapping(bytes32 => bool)) public nonceUsed;

    /// @dev Reentrancy guard (1 = unlocked, 2 = locked).
    uint256 private _lock = 1;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event Deposited(address indexed payer, address indexed token, uint256 amount);
    event Withdrawn(address indexed payer, address indexed token, uint256 amount);
    event PaymentSettled(
        address indexed payer, address indexed payee, address indexed token, uint256 amount, bytes32 nonce
    );

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier nonReentrant() {
        require(_lock == 1, "Quittance: reentrant call");
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor() {
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator();
    }

    // ---------------------------------------------------------------------
    // Deposit / withdraw
    // ---------------------------------------------------------------------

    /// @notice Deposit an ERC20 into your Quittance balance (approve Quittance for `amount` first).
    function deposit(address token, uint256 amount) external nonReentrant {
        require(token != address(0), "Quittance: use depositNative for native");
        require(amount > 0, "Quittance: amount must be greater than zero");
        _pullERC20(token, msg.sender, amount);
        balanceOf[msg.sender][token] += amount;
        emit Deposited(msg.sender, token, amount);
    }

    /// @notice Deposit native PHRS into your Quittance balance.
    function depositNative() external payable nonReentrant {
        require(msg.value > 0, "Quittance: amount must be greater than zero");
        balanceOf[msg.sender][address(0)] += msg.value;
        emit Deposited(msg.sender, address(0), msg.value);
    }

    /// @notice Withdraw your own unspent balance.
    function withdraw(address token, uint256 amount) external nonReentrant {
        require(amount > 0, "Quittance: amount must be greater than zero");
        require(balanceOf[msg.sender][token] >= amount, "Quittance: insufficient balance");
        balanceOf[msg.sender][token] -= amount;
        _payout(token, msg.sender, amount);
        emit Withdrawn(msg.sender, token, amount);
    }

    // ---------------------------------------------------------------------
    // Settlement
    // ---------------------------------------------------------------------

    /// @notice Settle a single signed payment voucher. Callable by anyone (a relayer / the
    ///         payee / an x402 facilitator); funds always go to `auth.payee`.
    function redeem(PaymentAuthorization calldata auth, bytes calldata signature) external nonReentrant {
        _settle(auth, signature);
    }

    /// @notice Settle many vouchers in one transaction (high-throughput agent micropayments).
    function redeemMany(PaymentAuthorization[] calldata auths, bytes[] calldata signatures)
        external
        nonReentrant
    {
        require(auths.length == signatures.length, "Quittance: length mismatch");
        for (uint256 i; i < auths.length; ++i) {
            _settle(auths[i], signatures[i]);
        }
    }

    /// @notice Read-only check (x402 "verify" step): would this voucher settle right now?
    /// @return ok     true if redeem would succeed.
    /// @return reason "ok" or a human-readable failure reason.
    function verify(PaymentAuthorization calldata auth, bytes calldata signature)
        external
        view
        returns (bool ok, string memory reason)
    {
        if (auth.amount == 0) return (false, "amount must be greater than zero");
        if (block.timestamp < auth.validAfter) return (false, "authorization not yet valid");
        if (auth.validBefore != 0 && block.timestamp > auth.validBefore) return (false, "authorization expired");
        if (nonceUsed[auth.payer][auth.nonce]) return (false, "nonce already used");
        if (!_isValidSignature(auth.payer, hashAuthorization(auth), signature)) return (false, "invalid signature");
        if (balanceOf[auth.payer][auth.token] < auth.amount) return (false, "insufficient payer balance");
        return (true, "ok");
    }

    // ---------------------------------------------------------------------
    // EIP-712 helpers
    // ---------------------------------------------------------------------

    /// @notice The EIP-712 domain separator for building/verifying vouchers off-chain.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    /// @notice The full EIP-712 digest for a voucher (sign this hash to authorize a payment).
    function hashAuthorization(PaymentAuthorization calldata auth) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                _PAYMENT_TYPEHASH,
                auth.payer,
                auth.payee,
                auth.token,
                auth.amount,
                auth.nonce,
                auth.validAfter,
                auth.validBefore
            )
        );
        return keccak256(abi.encodePacked(hex"1901", _domainSeparator(), structHash));
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _settle(PaymentAuthorization calldata auth, bytes calldata signature) private {
        require(auth.amount > 0, "Quittance: amount must be greater than zero");
        require(block.timestamp >= auth.validAfter, "Quittance: authorization not yet valid");
        require(auth.validBefore == 0 || block.timestamp <= auth.validBefore, "Quittance: authorization expired");
        require(!nonceUsed[auth.payer][auth.nonce], "Quittance: nonce already used");
        require(_isValidSignature(auth.payer, hashAuthorization(auth), signature), "Quittance: invalid signature");
        require(balanceOf[auth.payer][auth.token] >= auth.amount, "Quittance: insufficient payer balance");

        // effects before interaction
        nonceUsed[auth.payer][auth.nonce] = true;
        balanceOf[auth.payer][auth.token] -= auth.amount;

        _payout(auth.token, auth.payee, auth.amount);

        emit PaymentSettled(auth.payer, auth.payee, auth.token, auth.amount, auth.nonce);
    }

    /// @dev Verifies an EOA (ECDSA) or smart-account (EIP-1271) signature over `digest`.
    function _isValidSignature(address signer, bytes32 digest, bytes calldata signature)
        private
        view
        returns (bool)
    {
        if (signer.code.length > 0) {
            (bool ok, bytes memory ret) =
                signer.staticcall(abi.encodeWithSelector(IERC1271.isValidSignature.selector, digest, signature));
            return ok && ret.length == 32 && abi.decode(ret, (bytes4)) == _ERC1271_MAGIC;
        }
        return _recover(digest, signature) == signer;
    }

    /// @dev Malleability-resistant ECDSA recovery. Returns address(0) on any malformed input.
    function _recover(bytes32 digest, bytes calldata signature) private pure returns (address) {
        if (signature.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }
        if (uint256(s) > _HALF_N) return address(0);
        if (v != 27 && v != 28) return address(0);
        return ecrecover(digest, v, r, s);
    }

    function _domainSeparator() private view returns (bytes32) {
        return block.chainid == _CACHED_CHAIN_ID ? _CACHED_DOMAIN_SEPARATOR : _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                _EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("Quittance")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    function _payout(address token, address to, uint256 amount) private {
        if (token == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            require(ok, "Quittance: native transfer failed");
        } else {
            _pushERC20(token, to, amount);
        }
    }

    /// @dev transferFrom tolerant of non-standard ERC20s that return no value.
    function _pullERC20(address token, address from, uint256 amount) private {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, address(this), amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "Quittance: ERC20 transferFrom failed");
    }

    /// @dev transfer tolerant of non-standard ERC20s that return no value.
    function _pushERC20(address token, address to, uint256 amount) private {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "Quittance: ERC20 transfer failed");
    }
}
