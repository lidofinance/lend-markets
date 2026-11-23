// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {CentrifugeNavOracle, ICentrifugeSpoke} from "../../../src/oracle/CentrifugeNavOracle.sol";
import {ForkCollateralIssuer} from "./ForkCollateralIssuer.sol";

/// @dev A Centrifuge share token's transfer hook, and the hook's member list.
interface ICentrifugeShareToken {
    function hook() external view returns (address);
}

interface ICentrifugeMemberHook {
    function root() external view returns (address);
    function updateMember(address token, address user, uint64 validUntil) external;
}

/// @notice Centrifuge: a share class's price on the Spoke, and share tokens whose transfer hook may keep a member list,
///         the allowlist of the accounts that may receive the token. The Spoke stamps a published price with the time
///         it was computed, so the price goes stale `MAX_PRICE_AGE` after its publication.
contract ForkCollateralIssuerCentrifuge is ForkCollateralIssuer {
    /// @dev The collateral's hook when it keeps a member list; zero otherwise.
    ICentrifugeMemberHook private immutable MEMBER_LIST;
    /// @dev The Spoke call that returns when the price was computed.
    bytes private priceComputedAtCall;

    constructor(address oracle, address collateral)
        ForkCollateralIssuer(
            oracle,
            collateral,
            address(CentrifugeNavOracle(oracle).SPOKE()),
            abi.encodeCall(
                ICentrifugeSpoke.pricePoolPerShare,
                (CentrifugeNavOracle(oracle).POOL_ID(), CentrifugeNavOracle(oracle).SHARE_CLASS_ID(), false)
            )
        )
    {
        priceComputedAtCall = abi.encodeCall(
            ICentrifugeSpoke.markersPricePoolPerShare,
            (CentrifugeNavOracle(oracle).POOL_ID(), CentrifugeNavOracle(oracle).SHARE_CLASS_ID())
        );
        MEMBER_LIST = _memberList(collateral);
    }

    /// @notice The hook's root adds `account` to the member list, when the collateral keeps one.
    function addToAllowlist(address account) public override {
        if (address(MEMBER_LIST) == address(0)) return;
        vm.prank(MEMBER_LIST.root());
        MEMBER_LIST.updateMember(COLLATERAL, account, type(uint64).max);
    }

    /// @dev The Spoke publishes `value`, computed now.
    function _publish(uint256 value) internal override {
        super._publish(value);
        vm.mockCall(PRICE_SOURCE, priceComputedAtCall, abi.encode(uint64(block.timestamp), uint64(0), uint64(0)));
    }

    /// @dev The hook of `collateral` when it keeps a member list; zero otherwise.
    function _memberList(address collateral) private view returns (ICentrifugeMemberHook) {
        (bool ok, bytes memory returned) = collateral.staticcall(abi.encodeCall(ICentrifugeShareToken.hook, ()));
        if (!ok || returned.length != 32) return ICentrifugeMemberHook(address(0));
        ICentrifugeMemberHook hook = abi.decode(returned, (ICentrifugeMemberHook));
        (ok, returned) = address(hook).staticcall(abi.encodeCall(ICentrifugeMemberHook.root, ()));
        return ok && returned.length == 32 ? hook : ICentrifugeMemberHook(address(0));
    }
}
