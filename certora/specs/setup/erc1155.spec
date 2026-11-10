// CVL ERC1155 model for out-of-scene tokens: a NONDET transfer backstop and a balance draw.

methods {
    function _.safeTransferFrom(address, address, uint256, uint256, bytes) external => NONDET;
    function _.balanceOf(address account, uint256 id) external
        => ghostERC1155Balances[calledContract][account][id] expect uint256;
}

persistent ghost mapping(address => mapping(address => mapping(uint256 => uint256))) ghostERC1155Balances;
