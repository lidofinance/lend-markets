// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {Call, IBundler3} from "@bundler3/src/interfaces/IBundler3.sol";
import {ErrorsLib} from "@bundler3/src/libraries/ErrorsLib.sol";

import {LidoLendVaultAdapter} from "../../src/adapters/LidoLendVaultAdapter.sol";

/// @dev Vault stand-in recording the exit arguments and returning settable payouts, so the adapter's
///      owner pinning, sentinel resolution, and both payout floors are checkable in isolation.
contract MockExitVault {
    uint256 public retSharesBurned;
    uint256 public retLoanAssets;
    uint256 public retCollateralSeized;
    uint256 public retDebtCanceled;

    uint256 public lastShares;
    address public lastReceiver;
    address public lastOwner;
    uint256 public lastMaxIterations;

    mapping(address => uint256) public balanceOf;

    function setBalance(address account, uint256 balance) external {
        balanceOf[account] = balance;
    }

    function setReturns(uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled)
        external
    {
        retSharesBurned = sharesBurned;
        retLoanAssets = loanAssets;
        retCollateralSeized = collateralSeized;
        retDebtCanceled = debtCanceled;
    }

    function fallbackExit(uint256 shares, address receiver, address owner, uint256 maxIterations)
        external
        returns (uint256, uint256, uint256, uint256)
    {
        lastShares = shares;
        lastReceiver = receiver;
        lastOwner = owner;
        lastMaxIterations = maxIterations;
        return (retSharesBurned, retLoanAssets, retCollateralSeized, retDebtCanceled);
    }
}

/// @notice Unit coverage of the LidoLendVaultAdapter: sender gating, owner pinning, share sentinel,
///         and the split-invariant exit floors, against a mock vault. The stock Bundler3 dispatcher is
///         artifact-deployed (it pins solc 0.8.28). The mock exposes no oracle and no market params:
///         compiling proves the adapter values the exit purely from the vault's returned accounting.
contract LidoLendVaultAdapterTest is Test {
    IBundler3 internal bundler3;
    LidoLendVaultAdapter internal vaultAdapter;
    MockExitVault internal vault;

    address internal user;

    function setUp() public {
        bundler3 = IBundler3(deployCode("Bundler3.sol:Bundler3"));
        vaultAdapter = new LidoLendVaultAdapter(address(bundler3));
        vault = new MockExitVault();
        user = makeAddr("user");
    }

    function _exec(uint256 shares, uint256 maxIterations, uint256 minExitAssets, uint256 minSharesBurned) internal {
        Call[] memory bundle = new Call[](1);
        bundle[0] = Call(
            address(vaultAdapter),
            abi.encodeCall(
                vaultAdapter.fallbackExit, (address(vault), shares, maxIterations, user, minExitAssets, minSharesBurned)
            ),
            0,
            false,
            bytes32(0)
        );
        vm.prank(user);
        bundler3.multicall(bundle);
    }

    // ── gating and argument pinning ──

    function testRevert_fallbackExit_unauthorizedSenderOutsideBundle() public {
        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        vaultAdapter.fallbackExit(address(vault), 1, 0, user, 0, 0);
    }

    function test_fallbackExit_ownerAlwaysInitiator() public {
        vault.setBalance(user, 10 ether);
        vault.setReturns(10 ether, 1 ether, 0, 0);

        _exec(10 ether, 7, 0, 0);

        assertEq(vault.lastOwner(), user, "owner pinned to the bundle initiator");
        assertEq(vault.lastReceiver(), user);
        assertEq(vault.lastMaxIterations(), 7, "iteration cap forwarded");
    }

    function test_fallbackExit_maxSentinelUsesInitiatorBalance() public {
        vault.setBalance(user, 42 ether);
        vault.setReturns(42 ether, 1 ether, 0, 0);

        _exec(type(uint256).max, 0, 0, 0);

        assertEq(vault.lastShares(), 42 ether, "sentinel resolved against the initiator's shares");
    }

    function testRevert_fallbackExit_zeroShares() public {
        // Explicit zero and a max sentinel over an empty position both revert before the vault call.
        Call[] memory bundle = new Call[](1);
        bundle[0] = Call(
            address(vaultAdapter),
            abi.encodeCall(vaultAdapter.fallbackExit, (address(vault), 0, 0, user, 0, 0)),
            0,
            false,
            bytes32(0)
        );
        vm.prank(user);
        vm.expectRevert(ErrorsLib.ZeroShares.selector);
        bundler3.multicall(bundle);

        bundle[0].data = abi.encodeCall(vaultAdapter.fallbackExit, (address(vault), type(uint256).max, 0, user, 0, 0));
        vm.prank(user);
        vm.expectRevert(ErrorsLib.ZeroShares.selector);
        bundler3.multicall(bundle);
    }

    function testRevert_fallbackExit_zeroReceiver() public {
        Call[] memory bundle = new Call[](1);
        bundle[0] = Call(
            address(vaultAdapter),
            abi.encodeCall(vaultAdapter.fallbackExit, (address(vault), 1, 0, address(0), 0, 0)),
            0,
            false,
            bytes32(0)
        );
        vm.prank(user);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        bundler3.multicall(bundle);
    }

    // ── burn floor ──

    function test_fallbackExit_burnFloorBoundary() public {
        vault.setBalance(user, 10 ether);
        vault.setReturns(6 ether, 1 ether, 0, 0);

        // Exactly the burned amount passes.
        _exec(10 ether, 0, 0, 6 ether);
    }

    function testRevert_fallbackExit_burnBelowMinimum() public {
        vault.setBalance(user, 10 ether);
        vault.setReturns(6 ether, 1 ether, 0, 0);

        Call[] memory bundle = new Call[](1);
        bundle[0] = Call(
            address(vaultAdapter),
            abi.encodeCall(vaultAdapter.fallbackExit, (address(vault), 10 ether, 0, user, 0, 6 ether + 1)),
            0,
            false,
            bytes32(0)
        );
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(LidoLendVaultAdapter.BurnBelowMinimum.selector, 6 ether, 6 ether + 1));
        bundler3.multicall(bundle);
    }

    // ── exit-value floor ──

    function test_fallbackExit_valueFloorBoundaryWithBothLegs() public {
        vault.setBalance(user, 10 ether);
        vault.setReturns(10 ether, 3 ether, 8 ether, 5 ether);

        // Exit value = loan assets + debt cancelled; passes at exactly the floor.
        _exec(10 ether, 0, 3 ether + 5 ether, 0);
    }

    function testRevert_fallbackExit_valueBelowFloor() public {
        vault.setBalance(user, 10 ether);
        vault.setReturns(10 ether, 3 ether, 8 ether, 5 ether);
        uint256 value = 3 ether + 5 ether;

        Call[] memory bundle = new Call[](1);
        bundle[0] = Call(
            address(vaultAdapter),
            abi.encodeCall(vaultAdapter.fallbackExit, (address(vault), 10 ether, 0, user, value + 1, 0)),
            0,
            false,
            bytes32(0)
        );
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(LidoLendVaultAdapter.ExitBelowMinimum.selector, value, value + 1));
        bundler3.multicall(bundle);
    }

    function testRevert_fallbackExit_floorIgnoresCollateralQuantity() public {
        // The floor follows the market's accounting (debt cancelled), never the raw collateral amount:
        // a huge seizure with tiny cancelled debt still reverts a floor just above the accounted value.
        vault.setBalance(user, 10 ether);
        vault.setReturns(10 ether, 1 ether, 1_000_000 ether, 2 wei);

        Call[] memory bundle = new Call[](1);
        bundle[0] = Call(
            address(vaultAdapter),
            abi.encodeCall(vaultAdapter.fallbackExit, (address(vault), 10 ether, 0, user, 1 ether + 3 wei, 0)),
            0,
            false,
            bytes32(0)
        );
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(LidoLendVaultAdapter.ExitBelowMinimum.selector, 1 ether + 2 wei, 1 ether + 3 wei)
        );
        bundler3.multicall(bundle);
    }

    // ── floor consistency under fuzz ──

    function testFuzz_fallbackExit_floorMatchesReturnedAccounting(
        uint128 loanAssets,
        uint128 debtCanceled,
        uint128 collateralSeized,
        uint128 minExitAssets
    ) public {
        vault.setBalance(user, 1 ether);
        vault.setReturns(1 ether, loanAssets, collateralSeized, debtCanceled);
        uint256 value = uint256(loanAssets) + debtCanceled;

        Call[] memory bundle = new Call[](1);
        bundle[0] = Call(
            address(vaultAdapter),
            abi.encodeCall(vaultAdapter.fallbackExit, (address(vault), 1 ether, 0, user, minExitAssets, 0)),
            0,
            false,
            bytes32(0)
        );
        vm.prank(user);
        if (value < minExitAssets) {
            vm.expectRevert(
                abi.encodeWithSelector(LidoLendVaultAdapter.ExitBelowMinimum.selector, value, minExitAssets)
            );
        }
        bundler3.multicall(bundle);
    }
}
