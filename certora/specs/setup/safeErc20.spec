// OZ SafeERC20 routed into the shared ERC20 model (forceApprove's inline-assembly call
// would break points-to analysis if left native).

import "erc20.spec";

methods {
    function SafeERC20.safeTransfer(address token, address to, uint256 value)
        internal => safeTransferOzERC20CVL(token, calledContract, to, value);
    function SafeERC20.safeTransferFrom(address token, address from, address to, uint256 value)
        internal => safeTransferFromOzERC20CVL(token, calledContract, from, to, value);
    function SafeERC20.forceApprove(address token, address spender, uint256 value)
        internal => forceApproveERC20CVL(token, calledContract, spender, value);
}

function safeTransferOzERC20CVL(address token, address src, address to, uint256 value) {
    transferERC20CVL(token, src, to, value);
}

function safeTransferFromOzERC20CVL(address token, address spender, address from, address to, uint256 value) {
    transferFromERC20CVL(token, spender, from, to, value);
}

function forceApproveERC20CVL(address token, address owner, address spender, uint256 value) {
    approveERC20CVL(token, owner, spender, value);
}
