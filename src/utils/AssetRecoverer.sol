// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title AssetRecoverer
 * @dev Abstract contract providing mechanisms for recovering various asset types (ETH, ERC20, ERC721, ERC1155) from a
 * contract.
 * This contract is designed to allow asset recovery by the owner.
 * @notice Assets are recovered to a recipient specified by the owner.
 */
abstract contract AssetRecoverer is Ownable {
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
    // RECOVERY
    // ---

    /**
     * @dev Allows the owner to recover Ether held by the contract.
     * @param recipient The address that receives the recovered Ether.
     * Emits an EtherRecovered event upon success.
     */
    function recoverEther(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroRecipient();
        uint256 amount = address(this).balance;

        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert EtherTransferFailed();

        emit EtherRecovered(recipient, amount);
    }

    /**
     * @dev Allows the owner to recover ERC20 tokens held by the contract.
     * @param token The address of the ERC20 token to recover.
     * @param recipient The address that receives the recovered tokens.
     * @param amount The amount of the ERC20 token to recover.
     * Emits an ERC20Recovered event upon success.
     */
    function recoverERC20(address token, address recipient, uint256 amount) external onlyOwner {
        if (recipient == address(0)) revert ZeroRecipient();
        IERC20(token).safeTransfer(recipient, amount);
        emit ERC20Recovered(token, recipient, amount);
    }

    /**
     * @dev Allows the owner to recover ERC721 tokens held by the contract.
     * @param token The address of the ERC721 token to recover.
     * @param recipient The address that receives the recovered token.
     * @param tokenId The token ID of the ERC721 token to recover.
     * Emits an ERC721Recovered event upon success.
     */
    function recoverERC721(address token, address recipient, uint256 tokenId) external onlyOwner {
        if (recipient == address(0)) revert ZeroRecipient();
        IERC721(token).safeTransferFrom(address(this), recipient, tokenId);
        emit ERC721Recovered(token, tokenId, recipient);
    }

    /**
     * @dev Allows the owner to recover ERC1155 tokens held by the contract.
     * @param token The address of the ERC1155 token to recover.
     * @param recipient The address that receives the recovered tokens.
     * @param tokenId The token ID of the ERC1155 token to recover.
     * Emits an ERC1155Recovered event upon success.
     */
    function recoverERC1155(address token, address recipient, uint256 tokenId) external onlyOwner {
        if (recipient == address(0)) revert ZeroRecipient();
        uint256 amount = IERC1155(token).balanceOf(address(this), tokenId);
        IERC1155(token).safeTransferFrom(address(this), recipient, tokenId, amount, "");
        emit ERC1155Recovered(token, tokenId, recipient, amount);
    }
}
