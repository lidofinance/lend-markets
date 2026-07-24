// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

// Mainnet-fork mirror of the IRM model-selection scenario. The mock-token flavour, the shared
// `IrmScenarioBase` harness, the candidate IRMs, and the adaptive parameter-upgrade tests stay in
// `test/scenario/IrmModelSelection.t.sol`; only the fork flavour lives here so every fork suite is under
// `test/fork/`. Not production code.

import {IrmScenarioBase} from "../scenario/IrmModelSelection.t.sol";
import {ForkTest} from "./helpers/ForkTest.sol";

interface IWETHFork {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
}

interface IStETHFork {
    function submit(address) external payable returns (uint256);
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IWstETHFork {
    function wrap(uint256) external returns (uint256);
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function stEthPerToken() external view returns (uint256);
}

/// @notice Fork mirror of the simulation against real WETH/wstETH. Loan funding wraps ETH to WETH;
///         collateral funding submits ETH to Lido and wraps stETH to wstETH; staking moves are simulated by
///         mocking the real wstETH `stEthPerToken`. `setUp` creates the fork and reads the token addresses
///         from the committed `NETWORK` config.
contract IrmModelSelectionForkTest is IrmScenarioBase, ForkTest {
    // Populated in setUp from script/config/<NETWORK>.toml.
    address internal WETH;
    address internal STETH;
    address internal WSTETH;

    function setUp() public {
        _fork();
        WETH = _ext("weth");
        STETH = _ext("stEth");
        WSTETH = _ext("wstEth");
    }

    function _setupTokens() internal override {
        loanToken = WETH;
        collateralToken = WSTETH;
    }

    function _fundLoan(address to, uint256 amount) internal override {
        vm.deal(to, amount);
        vm.prank(to);
        IWETHFork(WETH).deposit{value: amount}();
        vm.prank(to);
        IWETHFork(WETH).approve(address(market), type(uint256).max);
    }

    function _fundCollateral(address to, uint256 amount) internal override {
        uint256 eth = amount * 13 / 10 + 1 ether;
        vm.deal(to, eth);
        vm.prank(to);
        IStETHFork(STETH).submit{value: eth}(address(0));
        uint256 st = IStETHFork(STETH).balanceOf(to);
        vm.prank(to);
        IStETHFork(STETH).approve(WSTETH, st);
        vm.prank(to);
        IWstETHFork(WSTETH).wrap(st);
        vm.prank(to);
        IWstETHFork(WSTETH).approve(address(market), type(uint256).max);
        require(IWstETHFork(WSTETH).balanceOf(to) >= amount, "fork: insufficient wstETH wrapped");
    }

    function _setStakingIndex(uint256 index) internal override {
        vm.mockCall(WSTETH, abi.encodeWithSelector(IWstETHFork.stEthPerToken.selector), abi.encode(index));
    }

    function _currentStakingIndex() internal view override returns (uint256) {
        return IWstETHFork(WSTETH).stEthPerToken();
    }

    /// @dev Runs the multi-year IRM comparison scenario driven by the adaptive-curve IRM against real fork tokens.
    function test_scenario_adaptive() public {
        _run(IrmKind.Adaptive);
    }

    /// @dev Runs the multi-year IRM comparison scenario driven by the staking-pegged IRM against real fork tokens.
    function test_scenario_pegged() public {
        _run(IrmKind.Pegged);
    }

    /// @dev Runs the multi-year IRM comparison scenario driven by the linear-kink IRM against real fork tokens.
    function test_scenario_kinked() public {
        _run(IrmKind.Kinked);
    }

    /// @dev Runs the multi-year IRM comparison scenario driven by the capD dynamic-ceiling IRM against real fork
    /// tokens.
    function test_scenario_capD() public {
        _run(IrmKind.CapD);
    }
}
