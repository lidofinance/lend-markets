// CVL ERC721 model for out-of-scene tokens: the recovery transfer is a NONDET backstop.

methods {
    function _.safeTransferFrom(address, address, uint256) external => NONDET;
}
