// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IOracle} from "@lido-lend/src/interfaces/IOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Plays the issuer of one market's collateral on the fork: deals the collateral to test accounts, adds them
///         to the collateral's allowlist where it keeps one, and publishes the value of the price source that the
///         market's oracle reads, from which the oracle computes its price as it does live. One contract per issuer;
///         its constructor finds the price source behind the oracle and reverts on an oracle of another issuer.
abstract contract ForkCollateralIssuer is CommonBase, StdCheats {
    address internal immutable COLLATERAL;
    address internal immutable PRICE_SOURCE;
    /// @dev The exact call that the oracle makes on its price source.
    bytes internal priceSourceCall;
    /// @dev The source's value and the oracle's price at creation. An oracle's price is linear in its source's value,
    ///      so this pair converts any price into the source value that gives it.
    uint256 private immutable SOURCE_VALUE_AT_CREATION;
    uint256 private immutable PRICE_AT_CREATION;

    constructor(address oracle, address collateral, address priceSource, bytes memory sourceCall) {
        COLLATERAL = collateral;
        PRICE_SOURCE = priceSource;
        priceSourceCall = sourceCall;
        (bool ok, bytes memory returned) = priceSource.staticcall(sourceCall);
        require(ok && returned.length == 32, "ForkCollateralIssuer: the price source does not price");
        SOURCE_VALUE_AT_CREATION = abi.decode(returned, (uint256));
        PRICE_AT_CREATION = IOracle(oracle).price();
    }

    /// @notice Publishes the source value that makes the oracle return about `price`; returns that value.
    function setOraclePrice(uint256 price) external returns (uint256 value) {
        value = Math.mulDiv(SOURCE_VALUE_AT_CREATION, price, PRICE_AT_CREATION);
        _publish(value);
    }

    /// @notice The price source reverts with `revertData`, so the oracle's `price()` does too.
    function revertOracleSource(bytes calldata revertData) external {
        vm.mockCallRevert(PRICE_SOURCE, priceSourceCall, revertData);
    }

    /// @notice `to` joins the allowlist and receives `amount` of the collateral by a transfer from a holder that
    ///         `deal` funds, as a holder receives it live; a `deal` to `to` itself would overwrite a token that keeps
    ///         the allowlist entry in the bits of the balance slot, as a Centrifuge share token does.
    function dealCollateral(address to, uint256 amount) external {
        addToAllowlist(to);
        address holder = makeAddr("forkCollateralIssuer.holder");
        deal(COLLATERAL, holder, amount);
        vm.prank(holder);
        require(IERC20(COLLATERAL).transfer(to, amount), "ForkCollateralIssuer: collateral transfer failed");
    }

    /// @notice Adds `account` to the allowlist of the accounts that may receive the collateral; nothing to do for a
    ///         collateral that keeps none.
    function addToAllowlist(address account) public virtual {}

    /// @dev Every later call of `priceSourceCall` returns `value`; the source's other calls keep their live values.
    function _publish(uint256 value) internal virtual {
        vm.mockCall(PRICE_SOURCE, priceSourceCall, abi.encode(value));
    }
}
