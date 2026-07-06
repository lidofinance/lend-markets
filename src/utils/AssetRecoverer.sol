// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title AssetRecoverer
/// @notice Recovers ETH, ERC-20, ERC-721, and ERC-1155 tokens held by the contract, to a caller-specified
///         recipient. Gated by `_checkRecoverer`, implemented by the inheriting contract.
abstract contract AssetRecoverer {
    using SafeERC20 for IERC20;

    // ---
    // EVENTS
    // ---

    event EtherRecovered(address indexed recipient, uint256 amount);
    event ERC20Recovered(address indexed token, address indexed recipient, uint256 amount);
    event ERC721Recovered(address indexed token, uint256 tokenId, address indexed recipient);
    event ERC1155Recovered(address indexed token, uint256 tokenId, address indexed recipient, uint256 amount);

    // ---
    // ERRORS
    // ---

    /// @notice The recovery recipient was the zero address.
    error ZeroRecipient();

    /// @notice The Ether transfer to the recipient failed.
    error EtherTransferFailed();

    // ---
    // MODIFIERS
    // ---

    /// @dev Guards every recovery function; delegates the permission check to `_checkRecoverer`.
    modifier onlyRecoverer() {
        _checkRecoverer();
        _;
    }

    // ---
    // PERMISSIONS
    // ---

    /// @dev Permission check for the recovery functions. The inheriting contract must implement it (e.g. by
    ///      calling `_checkOwner`) to set who may recover.
    function _checkRecoverer() internal view virtual;

    // ---
    // RECOVERY
    // ---

    /// @notice Recover the contract's full Ether balance to `recipient`.
    function recoverEther(address recipient) external onlyRecoverer {
        if (recipient == address(0)) revert ZeroRecipient();
        uint256 amount = address(this).balance;

        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert EtherTransferFailed();

        emit EtherRecovered(recipient, amount);
    }

    /// @notice Recover `amount` of the ERC-20 `token` to `recipient`.
    function recoverERC20(address token, address recipient, uint256 amount) external onlyRecoverer {
        if (recipient == address(0)) revert ZeroRecipient();
        IERC20(token).safeTransfer(recipient, amount);
        emit ERC20Recovered(token, recipient, amount);
    }

    /// @notice Recover `tokenId` of the ERC-721 `token` to `recipient`.
    function recoverERC721(address token, address recipient, uint256 tokenId) external onlyRecoverer {
        if (recipient == address(0)) revert ZeroRecipient();
        IERC721(token).safeTransferFrom(address(this), recipient, tokenId);
        emit ERC721Recovered(token, tokenId, recipient);
    }

    /// @notice Recover the full balance of `tokenId` of the ERC-1155 `token` to `recipient`.
    function recoverERC1155(address token, address recipient, uint256 tokenId) external onlyRecoverer {
        if (recipient == address(0)) revert ZeroRecipient();
        uint256 amount = IERC1155(token).balanceOf(address(this), tokenId);
        IERC1155(token).safeTransferFrom(address(this), recipient, tokenId, amount, "");
        emit ERC1155Recovered(token, tokenId, recipient, amount);
    }
}
