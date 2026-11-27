// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {Authorization, Market as MorphoMarket, Signature} from "@lido-lend/src/interfaces/IMorpho.sol";
import {AUTHORIZATION_TYPEHASH} from "@lido-lend/src/libraries/ConstantsLib.sol";
import {MathLib} from "@lido-lend/src/libraries/MathLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";
import {IrmKind, Market} from "../setup/Types.sol";

/// @dev Loan token with a USDT-style transfer fee, taken from the amount sent and paid to a sink.
contract TransferFeeToken is MockERC20 {
    address internal constant FEE_SINK = address(0xFEE);

    uint256 public feeBps;

    constructor() MockERC20("Fee Loan", "fLOAN", 18) {}

    function setFeeBps(uint256 newFeeBps) external {
        feeBps = newFeeBps;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (feeBps == 0 || from == address(0) || to == address(0)) {
            super._update(from, to, value);
        } else {
            uint256 fee = value * feeBps / 10_000;
            super._update(from, FEE_SINK, fee);
            super._update(from, to, value - fee);
        }
    }
}

/// @notice L2 behaviours the forked core keeps from upstream Morpho Blue and the Lido layer does not change, on a
///         freshly deployed stack: the protocol fee floored at each accrual, a signed authorization that outlives a
///         direct revocation, and a loan-token transfer fee the core does not measure.
contract CoreInheritedBehaviourTest is LidoLendSetup {
    using MarketActions for Market;
    using MathLib for uint256;
    using SharesMathLib for uint256;

    uint256 internal constant FEE = 0.1e18;

    // ── Protocol fee ──

    /// @dev The core floors the fee of each accrual separately, so n accruals mint up to n raw loan units less fee than
    ///      one fee on their summed interest, and the floored remainder stays with the lenders.
    function test_perAccrualFeeFloor_mintsLessFeeThanFeeOnSummedInterest() public {
        (Market storage m, uint256 lenderShares) = _deployFeeMarketWithDebt();
        uint256 n = 300; // one accrual per 12-second block for an hour

        MorphoMarket memory start = m.core.market(m.id);
        uint256 feeSum = _accrueEveryBlock(m, n);
        MorphoMarket memory end = m.core.market(m.id);
        uint256 interest = end.totalBorrowAssets - start.totalBorrowAssets;
        uint256 aggregateFee = interest.wMulDown(FEE);

        uint256 feeShares = m.core.position(m.id, m.core.feeRecipient()).supplyShares;
        uint256 recipientValue = feeShares.toAssetsDown(end.totalSupplyAssets, end.totalSupplyShares);
        assertGt(aggregateFee, recipientValue, "the per-accrual floors lose fee");
        assertLe(aggregateFee - recipientValue, n, "at most one raw unit lost per accrual");
        assertLe(recipientValue, feeSum, "the recipient holds at most the floored sum");
        // One raw unit: each accrual prices its fee shares at its floored fee to within one share, about 1e-6 raw
        // units, so only the floored conversion of the lender's shares is off.
        assertApproxEqAbs(
            lenderShares.toAssetsDown(end.totalSupplyAssets, end.totalSupplyShares),
            start.totalSupplyAssets + interest - feeSum,
            1,
            "the lender keeps the floored fee"
        );
    }

    // ── Signed authorizations ──

    /// @dev A direct revocation leaves the signer's nonce unchanged, so an unused signed grant still restores the
    ///      operator, which can then withdraw the signer's supply to itself.
    function test_signedGrantAfterDirectRevocation_restoresOperator() public {
        Market storage m = _deployMarket(new MockERC20("Loan", "LOAN", 18));
        (address alice, uint256 aliceKey) = makeAddrAndKey("alice");
        address operator = _actor("operator");
        _fund(m.loanToken, alice, 100 ether);
        uint256 shares = m.coreSupply(alice, 100 ether);
        (Authorization memory grant, Signature memory grantSig) =
            _signAuthorization(aliceKey, operator, true, block.timestamp + 365 days);

        vm.startPrank(alice);
        m.core.setAuthorization(operator, true);
        m.core.setAuthorization(operator, false);
        vm.stopPrank();
        assertEq(m.core.nonce(alice), 0, "a direct grant and revocation leave the nonce");

        vm.warp(block.timestamp + 30 days);
        vm.prank(operator);
        m.core.setAuthorizationWithSig(grant, grantSig);
        assertTrue(m.core.isAuthorized(alice, operator), "the old signature restores the operator");

        MorphoMarket memory mkt = m.core.market(m.id);
        uint256 expectedAssets = shares.toAssetsDown(mkt.totalSupplyAssets, mkt.totalSupplyShares);
        vm.prank(operator);
        m.core.withdraw(m.params, 0, shares, alice, operator);
        assertEq(m.loanToken.balanceOf(operator), expectedAssets, "the operator withdraws the supply to itself");
        assertEq(m.core.position(m.id, alice).supplyShares, 0, "alice's supply is gone");
    }

    /// @dev The signer cancels an unused grant by spending its nonce on a signed revocation.
    function testRevert_selfSignedRevocation_cancelsPendingGrant() public {
        Market storage m = _deployMarket(new MockERC20("Loan", "LOAN", 18));
        (address alice, uint256 aliceKey) = makeAddrAndKey("alice");
        address operator = _actor("operator");
        (Authorization memory grant, Signature memory grantSig) =
            _signAuthorization(aliceKey, operator, true, block.timestamp + 365 days);
        (Authorization memory revocation, Signature memory revocationSig) =
            _signAuthorization(aliceKey, operator, false, block.timestamp + 1 hours);

        vm.prank(alice);
        m.core.setAuthorizationWithSig(revocation, revocationSig);

        vm.prank(operator);
        vm.expectRevert(bytes("invalid nonce"));
        m.core.setAuthorizationWithSig(grant, grantSig);
    }

    // ── Loan-token transfer fee ──

    /// @dev The core and the vault credit the requested amount of an inbound transfer. Once the loan token charges a
    ///      transfer fee, a vault deposit or redeem whose fee is nonzero reverts, and a direct supply leaves the core
    ///      holding less than it owes by the fee.
    function test_loanTokenTransferFee_blocksVaultHops_leavesCoreShort() public {
        TransferFeeToken loan = new TransferFeeToken();
        Market storage m = _deployMarket(loan);
        address alice = _actor("alice");
        _fund(m.loanToken, alice, 1000 ether);
        uint256 aliceShares = m.vaultDeposit(alice, 1000 ether);

        loan.setFeeBps(10); // 0.1%

        address bob = _actor("bob");
        _fund(m.loanToken, bob, 100 ether);
        vm.prank(bob);
        m.loanToken.approve(address(m.vault), 100 ether);
        vm.prank(bob);
        vm.expectRevert(bytes("transferFrom reverted"));
        m.vault.deposit(100 ether, bob);

        vm.prank(alice);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientBalance.selector);
        m.vault.redeem(aliceShares, alice, alice);

        m.coreSupply(bob, 100 ether);
        MorphoMarket memory mkt = m.core.market(m.id);
        uint256 owed = mkt.totalSupplyAssets - mkt.totalBorrowAssets;
        assertEq(owed - m.loanToken.balanceOf(address(m.core)), 0.1 ether, "the core is short by the inbound fee");
    }

    // ── Fixtures ──

    /// @dev A 6-decimal loan market at a fixed 5% rate and a 10% fee: one lender supplies 10,000 tokens directly to
    ///      the core and one borrower takes 1,000 of them.
    function _deployFeeMarketWithDebt() internal returns (Market storage m, uint256 lenderShares) {
        irmKind = IrmKind.Fixed;
        fixedBorrowRate = uint256(0.05e18) / 365 days;
        m = _deployMarket(new MockERC20("Loan", "LOAN", 6));
        m.core.setFeeRecipient(_actor("feeRecipient"));
        m.core.setFee(m.params, FEE);
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 10_000e6);
        lenderShares = m.coreSupply(lender, 10_000e6);
        address borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 2_000 ether);
        m.supplyCollateral(borrower, 2_000 ether);
        m.activateCollateral();
        m.borrow(borrower, 1_000e6);
    }

    /// @dev Accrues once per 12-second block, `n` times, and returns the sum of the fees each accrual floors.
    function _accrueEveryBlock(Market storage m, uint256 n) internal returns (uint256 feeSum) {
        for (uint256 i; i < n; ++i) {
            vm.warp(block.timestamp + 12);
            uint256 borrowBefore = m.core.market(m.id).totalBorrowAssets;
            m.accrueInterest();
            feeSum += (m.core.market(m.id).totalBorrowAssets - borrowBefore).wMulDown(FEE);
        }
    }

    /// @dev A market over `loan` with a fresh 18-decimal collateral token.
    function _deployMarket(MockERC20 loan) internal returns (Market storage) {
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        return _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));
    }

    /// @dev EIP-712 authorization of `authorized` by the holder of `key` at the signer's current nonce.
    function _signAuthorization(uint256 key, address authorized, bool isAuthorized, uint256 deadline)
        internal
        view
        returns (Authorization memory auth, Signature memory sig)
    {
        address authorizer = vm.addr(key);
        auth = Authorization({
            authorizer: authorizer,
            authorized: authorized,
            isAuthorized: isAuthorized,
            nonce: protocol.core.nonce(authorizer),
            deadline: deadline
        });
        bytes32 digest = keccak256(
            bytes.concat(
                "\x19\x01", protocol.core.DOMAIN_SEPARATOR(), keccak256(abi.encode(AUTHORIZATION_TYPEHASH, auth))
            )
        );
        (sig.v, sig.r, sig.s) = vm.sign(key, digest);
    }
}
