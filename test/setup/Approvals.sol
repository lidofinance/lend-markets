// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice ERC-20 approvals that hold for every token the suites touch. Mainnet USDT returns no data from
///         `approve` (a declared `bool` return reverts on decode) and rejects a non-zero to non-zero allowance
///         change; standard tokens tolerate both accommodations, so one routine serves the mock and fork suites.
library Approvals {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice `owner` approves `spender` for `amount`, zeroing an existing non-zero allowance first.
    function approve(address token, address owner, address spender, uint256 amount) internal {
        if (amount != 0 && IERC20(token).allowance(owner, spender) != 0) _approve(token, owner, spender, 0);
        _approve(token, owner, spender, amount);
    }

    function _approve(address token, address owner, address spender, uint256 amount) private {
        vm.prank(owner);
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.approve, (spender, amount)));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "Approvals: approve failed");
    }
}
