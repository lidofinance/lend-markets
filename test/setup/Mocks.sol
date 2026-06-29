// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Plain ERC-20 with an open mint, so suites run on a bare local chain (no fork, no Lido). Decimals
///      are configurable to exercise non-18-decimal markets.
contract MockERC20 is ERC20 {
    uint8 private immutable _DECIMALS;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Constant-price oracle in the Morpho 1e36 convention (collateral-per-loan, scaled 1e36). Deployed
///      behind an `OssifiableProxy` like the real oracles, so the price lives in proxy storage and is set
///      via `initialize` (a constructor would write the impl's storage, not the proxy's). The setup seeds
///      it to a non-round value, never `1e36` parity.
contract MockPriceOracle {
    uint256 public price;

    /// @notice Sets the initial price; satisfies the proxy's mandatory init call.
    function initialize(uint256 price_) external {
        price = price_;
    }

    /// @dev Test hook to move the price (e.g. to push a borrower unhealthy).
    function setPrice(uint256 price_) external {
        price = price_;
    }
}
