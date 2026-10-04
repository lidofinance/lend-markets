// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

/// @notice The mainnet token surfaces the fork suites drive, declared once. Only the members a suite calls are
///         listed; the tokens themselves are the deployed mainnet contracts, never mocks.

/// @dev Canonical WETH9.
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Lido stETH: `submit` stakes ETH.
interface IStETH {
    function submit(address referral) external payable returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Lido wstETH. `getStETHByWstETH(1e36)` is the exact call the deployed rate oracle makes, so a suite
///      that mocks the collateral price mocks that member.
interface IWstETH {
    function wrap(uint256 stETHAmount) external returns (uint256);
    function getStETHByWstETH(uint256 wstETHAmount) external view returns (uint256);
    function stEthPerToken() external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Mainnet USDT: `approve` returns no data, so a `bool` return here would revert on decode. Also safe for
///      USDY (a declared-void call ignores any return data).
interface IERC20NoReturn {
    function approve(address spender, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}
