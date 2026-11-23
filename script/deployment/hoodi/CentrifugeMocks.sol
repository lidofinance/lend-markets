// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Hoodi mock of a Centrifuge member list: the accounts that may receive a share token, kept by its
///         root, the Hoodi deployer.
contract MemberListMock {
    address public immutable root;
    mapping(address token => mapping(address user => uint64)) public validUntil;

    constructor(address root_) {
        root = root_;
    }

    function updateMember(address token, address user, uint64 validUntil_) external {
        require(msg.sender == root, "MemberListMock: not the root");
        validUntil[token][user] = validUntil_;
    }

    function isMember(address token, address user) external view returns (bool) {
        return validUntil[token][user] >= block.timestamp;
    }
}

/// @notice Hoodi mock of a Centrifuge share token that its owner mints. With a member list, only a member
///         receives it, as JTRSY and JAAA; without one, anyone does, as deJTRSY and deJAAA.
contract ShareTokenMock is ERC20 {
    error NotMember(address account);

    uint8 internal immutable DECIMALS;
    address public immutable owner;
    MemberListMock public immutable hook;

    constructor(string memory name, string memory symbol, uint8 decimals_, address owner_, MemberListMock hook_)
        ERC20(name, symbol)
    {
        DECIMALS = decimals_;
        owner = owner_;
        hook = hook_;
    }

    function decimals() public view override returns (uint8) {
        return DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == owner, "ShareTokenMock: not the owner");
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (address(hook) != address(0) && to != address(0) && !hook.isMember(address(this), to)) revert NotMember(to);
        super._update(from, to, value);
    }
}

/// @notice Hoodi mock of the Centrifuge Spoke: each share class's token and price, which its owner, the Hoodi
///         deployer, publishes. A price is stamped with the time it is published, so it goes stale like the live one.
contract CentrifugeSpokeMock {
    struct ShareClass {
        uint64 poolId;
        bytes16 scId;
        address token;
        uint128 price;
    }

    struct Published {
        address token;
        uint128 price;
        uint64 computedAt;
    }

    address public immutable owner;
    mapping(uint64 poolId => mapping(bytes16 scId => Published)) internal _classes;

    constructor(address owner_, ShareClass[] memory classes) {
        owner = owner_;
        for (uint256 i; i < classes.length; ++i) {
            _classes[classes[i].poolId][classes[i].scId] =
                Published(classes[i].token, classes[i].price, uint64(block.timestamp));
        }
    }

    /// @notice Publishes `price` for the share class now.
    function setPrice(uint64 poolId, bytes16 scId, uint128 price) external {
        require(msg.sender == owner, "CentrifugeSpokeMock: not the owner");
        Published storage c = _class(poolId, scId);
        (c.price, c.computedAt) = (price, uint64(block.timestamp));
    }

    function shareToken(uint64 poolId, bytes16 scId) external view returns (address) {
        return _class(poolId, scId).token;
    }

    function pricePoolPerShare(uint64 poolId, bytes16 scId, bool) external view returns (uint128) {
        return _class(poolId, scId).price;
    }

    function markersPricePoolPerShare(uint64 poolId, bytes16 scId) external view returns (uint64, uint64, uint64) {
        return (_class(poolId, scId).computedAt, type(uint64).max, type(uint64).max);
    }

    function _class(uint64 poolId, bytes16 scId) private view returns (Published storage c) {
        c = _classes[poolId][scId];
        require(c.token != address(0), "CentrifugeSpokeMock: unknown share class");
    }
}

/// @notice The Hoodi Centrifuge mocks: a member list, JTRSY and JAAA on it, plain deJTRSY and deJAAA, and a
///         Spoke that prices the four at their mainnet prices of 2026-11-22. Each lives at its CREATE2 address through
///         the deterministic deployer, so the market scripts know it before it is deployed.
library CentrifugeMocks {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    /// @dev The Hoodi test multisig: the member list's root and the Spoke's and tokens' owner. It is part of each
    /// mock's creation code, so the scripts, the tests and the deploy share one set of addresses.
    address internal constant OWNER = 0xA6b2dbCCE7895347A62b4409d29bA7ce29A74655;

    uint64 internal constant JTRSY_POOL = 281474976710662;
    bytes16 internal constant JTRSY_CLASS = 0x00010000000000060000000000000001;
    uint64 internal constant JAAA_POOL = 281474976710663;
    bytes16 internal constant JAAA_CLASS = 0x00010000000000070000000000000001;
    uint64 internal constant DEJTRSY_POOL = 281474976710660;
    bytes16 internal constant DEJTRSY_CLASS = 0x00010000000000040000000000000001;
    uint64 internal constant DEJAAA_POOL = 281474976710659;
    bytes16 internal constant DEJAAA_CLASS = 0x00010000000000030000000000000001;

    function memberList() internal pure returns (address) {
        return _address("member-list", _memberListCode());
    }

    function jtrsy() internal pure returns (address) {
        return _address("JTRSY", _tokenCode("JTRSY", 6, memberList()));
    }

    function jaaa() internal pure returns (address) {
        return _address("JAAA", _tokenCode("JAAA", 6, memberList()));
    }

    function dejtrsy() internal pure returns (address) {
        return _address("deJTRSY", _tokenCode("deJTRSY", 18, address(0)));
    }

    function dejaaa() internal pure returns (address) {
        return _address("deJAAA", _tokenCode("deJAAA", 18, address(0)));
    }

    function spoke() internal pure returns (address) {
        return _address("spoke", _spokeCode());
    }

    /// @notice Deploys each contract that has no code yet at its address.
    function deployMissing() internal {
        _deploy(memberList(), "member-list", _memberListCode());
        _deploy(jtrsy(), "JTRSY", _tokenCode("JTRSY", 6, memberList()));
        _deploy(jaaa(), "JAAA", _tokenCode("JAAA", 6, memberList()));
        _deploy(dejtrsy(), "deJTRSY", _tokenCode("deJTRSY", 18, address(0)));
        _deploy(dejaaa(), "deJAAA", _tokenCode("deJAAA", 18, address(0)));
        _deploy(spoke(), "spoke", _spokeCode());
    }

    function _memberListCode() private pure returns (bytes memory) {
        return abi.encodePacked(type(MemberListMock).creationCode, abi.encode(OWNER));
    }

    function _tokenCode(string memory symbol, uint8 decimals, address hook) private pure returns (bytes memory) {
        return abi.encodePacked(
            type(ShareTokenMock).creationCode,
            abi.encode(string.concat(symbol, " (Hoodi mock)"), symbol, decimals, OWNER, hook)
        );
    }

    function _spokeCode() private pure returns (bytes memory) {
        CentrifugeSpokeMock.ShareClass[] memory classes = new CentrifugeSpokeMock.ShareClass[](4);
        classes[0] = CentrifugeSpokeMock.ShareClass(JTRSY_POOL, JTRSY_CLASS, jtrsy(), 1.1229e18);
        classes[1] = CentrifugeSpokeMock.ShareClass(JAAA_POOL, JAAA_CLASS, jaaa(), 1.0574e18);
        classes[2] = CentrifugeSpokeMock.ShareClass(DEJTRSY_POOL, DEJTRSY_CLASS, dejtrsy(), 1.0432e18);
        classes[3] = CentrifugeSpokeMock.ShareClass(DEJAAA_POOL, DEJAAA_CLASS, dejaaa(), 1.0558e18);
        return abi.encodePacked(type(CentrifugeSpokeMock).creationCode, abi.encode(OWNER, classes));
    }

    function _address(string memory name, bytes memory code) private pure returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, _salt(name), keccak256(code)));
        return address(uint160(uint256(hash)));
    }

    function _deploy(address target, string memory name, bytes memory code) private {
        if (target.code.length != 0) return;
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(_salt(name), code));
        require(ok && target.code.length != 0, string.concat("CentrifugeMocks: ", name, " not deployed"));
    }

    function _salt(string memory name) private pure returns (bytes32) {
        return keccak256(bytes(string.concat("lido-lend.hoodi.centrifuge-mock.", name)));
    }
}
