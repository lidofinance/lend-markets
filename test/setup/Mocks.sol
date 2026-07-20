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

/// @dev Minimal WETH9-style wrapped-native token, so bundle tests can exercise the native-ETH wrap leg
///      on a bare local chain.
contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "MockWETH: ETH transfer failed");
    }
}

/// @dev Minimal stETH stand-in: balances are pooled ether, `submit` mints 1:1 and reports shares at a
///      non-parity share price so staking slippage checks exercise real math. Open mint for funding.
contract MockStETH is ERC20 {
    uint256 public stEthPerShare = 1.16e18;

    constructor() ERC20("Mock stETH", "stETH") {}

    function submit(address) external payable returns (uint256 shares) {
        _mint(msg.sender, msg.value);
        shares = (msg.value * 1e18) / stEthPerShare;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Minimal wstETH stand-in over `MockStETH` at a non-parity rate. `unwrap` mints the stETH leg
///      instead of escrow accounting, so wstETH funded via `deal` stays unwrappable.
contract MockWstETH is ERC20 {
    MockStETH private immutable _ST_ETH;
    uint256 public stEthPerToken = 1.2e18;

    constructor(MockStETH stEth_) ERC20("Mock wstETH", "wstETH") {
        _ST_ETH = stEth_;
    }

    function stETH() external view returns (address) {
        return address(_ST_ETH);
    }

    function wrap(uint256 stETHAmount) external returns (uint256 wstAmount) {
        _ST_ETH.transferFrom(msg.sender, address(this), stETHAmount);
        wstAmount = (stETHAmount * 1e18) / stEthPerToken;
        _mint(msg.sender, wstAmount);
    }

    function unwrap(uint256 wstETHAmount) external returns (uint256 stETHAmount) {
        _burn(msg.sender, wstETHAmount);
        stETHAmount = (wstETHAmount * stEthPerToken) / 1e18;
        _ST_ETH.mint(msg.sender, stETHAmount);
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
