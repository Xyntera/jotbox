// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Quittance} from "../src/quittance/Quittance.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Minimal EIP-1271 smart account whose `owner` key authorizes payments.
contract MockSmartWallet {
    address public owner;
    bytes4 private constant MAGIC = 0x1626ba7e;

    constructor(address _owner) {
        owner = _owner;
    }

    function fund(Quittance rail) external payable {
        rail.depositNative{value: msg.value}();
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        if (sig.length != 65) return 0xffffffff;
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 0x20))
            v := byte(0, calldataload(add(sig.offset, 0x40)))
        }
        return ecrecover(hash, v, r, s) == owner ? MAGIC : bytes4(0xffffffff);
    }

    receive() external payable {}
}

contract QuittanceTest is Test {
    Quittance rail;
    MockERC20 token;

    uint256 payerPk;
    address payer;
    address payee = makeAddr("payee");
    address relayer = makeAddr("relayer");

    function setUp() public {
        rail = new Quittance();
        token = new MockERC20();
        (payer, payerPk) = makeAddrAndKey("payer");
        vm.deal(payer, 100 ether);
        vm.deal(relayer, 1 ether);
    }

    // --------------------------- helpers ---------------------------

    function _auth(address token_, uint256 amount, bytes32 nonce, uint256 validBefore)
        internal
        view
        returns (Quittance.PaymentAuthorization memory)
    {
        return Quittance.PaymentAuthorization({
            payer: payer,
            payee: payee,
            token: token_,
            amount: amount,
            nonce: nonce,
            validAfter: 0,
            validBefore: validBefore
        });
    }

    function _sign(uint256 pk, Quittance.PaymentAuthorization memory auth) internal view returns (bytes memory) {
        bytes32 digest = rail.hashAuthorization(auth);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // --------------------------- deposit / withdraw ---------------------------

    function test_DepositWithdrawNative() public {
        vm.prank(payer);
        rail.depositNative{value: 5 ether}();
        assertEq(rail.balanceOf(payer, address(0)), 5 ether);
        assertEq(address(rail).balance, 5 ether);

        uint256 before = payer.balance;
        vm.prank(payer);
        rail.withdraw(address(0), 2 ether);
        assertEq(payer.balance, before + 2 ether);
        assertEq(rail.balanceOf(payer, address(0)), 3 ether);
    }

    function test_DepositWithdrawERC20() public {
        token.mint(payer, 10 ether);
        vm.startPrank(payer);
        token.approve(address(rail), 10 ether);
        rail.deposit(address(token), 10 ether);
        vm.stopPrank();
        assertEq(rail.balanceOf(payer, address(token)), 10 ether);

        vm.prank(payer);
        rail.withdraw(address(token), 4 ether);
        assertEq(token.balanceOf(payer), 4 ether);
        assertEq(rail.balanceOf(payer, address(token)), 6 ether);
    }

    // --------------------------- settlement ---------------------------

    function test_RedeemNative_RelayerSubmits_PaysPayee() public {
        vm.prank(payer);
        rail.depositNative{value: 5 ether}();

        Quittance.PaymentAuthorization memory auth = _auth(address(0), 1 ether, keccak256("res-1"), 0);
        bytes memory sig = _sign(payerPk, auth);

        (bool ok, string memory reason) = rail.verify(auth, sig);
        assertTrue(ok);
        assertEq(reason, "ok");

        uint256 before = payee.balance;
        vm.prank(relayer); // anyone can relay; funds still go to payee
        rail.redeem(auth, sig);

        assertEq(payee.balance, before + 1 ether);
        assertEq(rail.balanceOf(payer, address(0)), 4 ether);
        assertTrue(rail.nonceUsed(payer, keccak256("res-1")));
    }

    function test_RedeemERC20() public {
        token.mint(payer, 10 ether);
        vm.startPrank(payer);
        token.approve(address(rail), 10 ether);
        rail.deposit(address(token), 10 ether);
        vm.stopPrank();

        Quittance.PaymentAuthorization memory auth = _auth(address(token), 3 ether, keccak256("res-erc20"), 0);
        bytes memory sig = _sign(payerPk, auth);

        rail.redeem(auth, sig);
        assertEq(token.balanceOf(payee), 3 ether);
        assertEq(rail.balanceOf(payer, address(token)), 7 ether);
    }

    function test_RedeemMany_Batch() public {
        vm.prank(payer);
        rail.depositNative{value: 5 ether}();

        Quittance.PaymentAuthorization[] memory auths = new Quittance.PaymentAuthorization[](3);
        bytes[] memory sigs = new bytes[](3);
        for (uint256 i; i < 3; ++i) {
            auths[i] = _auth(address(0), 1 ether, keccak256(abi.encode("batch", i)), 0);
            sigs[i] = _sign(payerPk, auths[i]);
        }

        uint256 before = payee.balance;
        rail.redeemMany(auths, sigs);
        assertEq(payee.balance, before + 3 ether);
        assertEq(rail.balanceOf(payer, address(0)), 2 ether);
    }

    function test_EIP1271_SmartWalletPayer() public {
        // owner key authorizes; the smart wallet is the payer-of-record.
        (address owner, uint256 ownerPk) = makeAddrAndKey("walletOwner");
        MockSmartWallet wallet = new MockSmartWallet(owner);
        vm.deal(address(this), 5 ether);
        wallet.fund{value: 5 ether}(rail);
        assertEq(rail.balanceOf(address(wallet), address(0)), 5 ether);

        Quittance.PaymentAuthorization memory auth = Quittance.PaymentAuthorization({
            payer: address(wallet),
            payee: payee,
            token: address(0),
            amount: 2 ether,
            nonce: keccak256("aa-res"),
            validAfter: 0,
            validBefore: 0
        });
        bytes32 digest = rail.hashAuthorization(auth);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        uint256 before = payee.balance;
        rail.redeem(auth, sig);
        assertEq(payee.balance, before + 2 ether);
        assertEq(rail.balanceOf(address(wallet), address(0)), 3 ether);
    }

    // --------------------------- reverts ---------------------------

    function test_RevertWhen_ReplayNonce() public {
        vm.prank(payer);
        rail.depositNative{value: 5 ether}();
        Quittance.PaymentAuthorization memory auth = _auth(address(0), 1 ether, keccak256("dup"), 0);
        bytes memory sig = _sign(payerPk, auth);

        rail.redeem(auth, sig);
        vm.expectRevert("Quittance: nonce already used");
        rail.redeem(auth, sig);
    }

    function test_RevertWhen_Expired() public {
        vm.prank(payer);
        rail.depositNative{value: 5 ether}();
        vm.warp(1000);
        Quittance.PaymentAuthorization memory auth = _auth(address(0), 1 ether, keccak256("exp"), 500);
        bytes memory sig = _sign(payerPk, auth);
        vm.expectRevert("Quittance: authorization expired");
        rail.redeem(auth, sig);
    }

    function test_RevertWhen_NotYetValid() public {
        vm.prank(payer);
        rail.depositNative{value: 5 ether}();
        Quittance.PaymentAuthorization memory auth = Quittance.PaymentAuthorization({
            payer: payer,
            payee: payee,
            token: address(0),
            amount: 1 ether,
            nonce: keccak256("future"),
            validAfter: block.timestamp + 1000,
            validBefore: 0
        });
        bytes memory sig = _sign(payerPk, auth);
        vm.expectRevert("Quittance: authorization not yet valid");
        rail.redeem(auth, sig);
    }

    function test_RevertWhen_InsufficientBalance() public {
        vm.prank(payer);
        rail.depositNative{value: 1 ether}();
        Quittance.PaymentAuthorization memory auth = _auth(address(0), 2 ether, keccak256("over"), 0);
        bytes memory sig = _sign(payerPk, auth);
        vm.expectRevert("Quittance: insufficient payer balance");
        rail.redeem(auth, sig);
    }

    function test_RevertWhen_BadSignature() public {
        vm.prank(payer);
        rail.depositNative{value: 5 ether}();
        (, uint256 wrongPk) = makeAddrAndKey("attacker");
        Quittance.PaymentAuthorization memory auth = _auth(address(0), 1 ether, keccak256("bad"), 0);
        bytes memory sig = _sign(wrongPk, auth); // signed by someone other than payer
        vm.expectRevert("Quittance: invalid signature");
        rail.redeem(auth, sig);
    }

    function test_RevertWhen_TamperedAmount() public {
        vm.prank(payer);
        rail.depositNative{value: 5 ether}();
        Quittance.PaymentAuthorization memory auth = _auth(address(0), 1 ether, keccak256("tamper"), 0);
        bytes memory sig = _sign(payerPk, auth);
        auth.amount = 4 ether; // change after signing -> digest mismatch
        vm.expectRevert("Quittance: invalid signature");
        rail.redeem(auth, sig);
    }

    function test_VerifyReflectsState() public {
        vm.prank(payer);
        rail.depositNative{value: 5 ether}();
        Quittance.PaymentAuthorization memory auth = _auth(address(0), 1 ether, keccak256("v"), 0);
        bytes memory sig = _sign(payerPk, auth);

        (bool ok,) = rail.verify(auth, sig);
        assertTrue(ok);
        rail.redeem(auth, sig);
        (bool ok2, string memory reason2) = rail.verify(auth, sig);
        assertFalse(ok2);
        assertEq(reason2, "nonce already used");
    }

    // --------------------------- fuzz ---------------------------

    function testFuzz_Redeem(uint96 deposit, uint96 amount, bytes32 nonce) public {
        deposit = uint96(bound(deposit, 1, 50 ether));
        amount = uint96(bound(amount, 1, deposit));
        vm.deal(payer, deposit);
        vm.prank(payer);
        rail.depositNative{value: deposit}();

        Quittance.PaymentAuthorization memory auth = _auth(address(0), amount, nonce, 0);
        bytes memory sig = _sign(payerPk, auth);

        uint256 before = payee.balance;
        rail.redeem(auth, sig);
        assertEq(payee.balance, before + amount);
        assertEq(rail.balanceOf(payer, address(0)), uint256(deposit) - amount);
    }
}
