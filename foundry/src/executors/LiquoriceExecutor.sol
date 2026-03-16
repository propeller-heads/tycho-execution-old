// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "@interfaces/IExecutor.sol";
import "../RestrictTransferFrom.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {
    IERC20,
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

/// @title LiquoriceExecutor
/// @notice Executor for Liquorice RFQ (Request for Quote) swaps
/// @dev Handles RFQ swaps through Liquorice settlement contracts with support for
///      partial fills and dynamic allowance management
contract LiquoriceExecutor is IExecutor, RestrictTransferFrom {
    using SafeERC20 for IERC20;
    using Address for address;

    /// @notice Liquorice-specific errors
    error LiquoriceExecutor__InvalidDataLength();
    error LiquoriceExecutor__ZeroAddress();
    error LiquoriceExecutor__AmountBelowMinimum();

    /// @notice The Liquorice settlement contract address
    address public immutable liquoriceSettlement;

    /// @notice The Liquorice balance manager contract address
    address public immutable liquoriceBalanceManager;

    constructor(
        address _liquoriceSettlement,
        address _liquoriceliquoriceBalanceManager,
        address _permit2
    ) RestrictTransferFrom(_permit2) {
        if (
            _liquoriceSettlement == address(0)
                || _liquoriceliquoriceBalanceManager == address(0)
        ) {
            revert LiquoriceExecutor__ZeroAddress();
        }
        liquoriceSettlement = _liquoriceSettlement;
        liquoriceBalanceManager = _liquoriceliquoriceBalanceManager;
    }

    /// @notice Executes a swap through Liquorice's RFQ system
    /// @param givenAmount The amount of input token to swap
    /// @param data Encoded swap data containing tokens and liquorice calldata
    /// @return calculatedAmount The amount of output token received
    function swap(uint256 givenAmount, bytes calldata data)
        external
        payable
        virtual
        override
        returns (uint256 calculatedAmount)
    {
        (
            address tokenIn,
            address tokenOut,
            TransferType transferType,
            uint32 partialFillOffset,
            uint256 originalBaseTokenAmount,
            uint256 minBaseTokenAmount,
            bool approvalNeeded,
            address receiver,
            bytes memory liquoriceCalldata
        ) = _decodeData(data);

        // Grant approval to Liquorice balance manager if needed
        if (approvalNeeded && tokenIn != address(0)) {
            // slither-disable-next-line unused-return
            IERC20(tokenIn)
                .forceApprove(liquoriceBalanceManager, type(uint256).max);
        }

        givenAmount = _clampAmount(
            givenAmount, originalBaseTokenAmount, minBaseTokenAmount
        );

        // Transfer tokens to executor
        _transfer(address(this), transferType, tokenIn, givenAmount);

        // Modify the fill amount in the calldata if partial fill is supported
        // If partialFillOffset is 0, partial fill is not supported
        bytes memory finalCalldata = liquoriceCalldata;
        if (partialFillOffset > 0 && originalBaseTokenAmount > givenAmount) {
            finalCalldata = _modifyFilledTakerAmount(
                liquoriceCalldata, givenAmount, partialFillOffset
            );
        }

        uint256 balanceBefore = _balanceOf(tokenOut, receiver);
        uint256 ethValue = tokenIn == address(0) ? givenAmount : 0;

        // Execute the swap by forwarding calldata to settlement contract
        // slither-disable-next-line unused-return
        liquoriceSettlement.functionCallWithValue(finalCalldata, ethValue);

        uint256 balanceAfter = _balanceOf(tokenOut, receiver);
        calculatedAmount = balanceAfter - balanceBefore;
    }

    /// @dev Decodes the packed calldata
    function _decodeData(bytes calldata data)
        internal
        pure
        returns (
            address tokenIn,
            address tokenOut,
            TransferType transferType,
            uint32 partialFillOffset,
            uint256 originalBaseTokenAmount,
            uint256 minBaseTokenAmount,
            bool approvalNeeded,
            address receiver,
            bytes memory liquoriceCalldata
        )
    {
        // Minimum fixed fields:
        // tokenIn (20) + tokenOut (20) + transferType (1) + partialFillOffset (4) +
        // originalBaseTokenAmount (32) + minBaseTokenAmount (32) +
        // approvalNeeded (1) + receiver (20) = 130 bytes
        if (data.length < 130) revert LiquoriceExecutor__InvalidDataLength();

        tokenIn = address(bytes20(data[0:20]));
        tokenOut = address(bytes20(data[20:40]));
        transferType = TransferType(uint8(data[40]));
        partialFillOffset = uint32(bytes4(data[41:45]));
        originalBaseTokenAmount = uint256(bytes32(data[45:77]));
        minBaseTokenAmount = uint256(bytes32(data[77:109]));
        approvalNeeded = data[109] != 0;
        receiver = address(bytes20(data[110:130]));
        liquoriceCalldata = data[130:];
    }

    /// @dev Clamps the given amount to be within the valid range for the quote
    /// @param givenAmount The amount provided by the router
    /// @param originalBaseTokenAmount The maximum amount the quote supports
    /// @param minBaseTokenAmount The minimum amount required for partial fills
    /// @return The clamped amount
    function _clampAmount(
        uint256 givenAmount,
        uint256 originalBaseTokenAmount,
        uint256 minBaseTokenAmount
    ) internal pure returns (uint256) {
        // For partially filled quotes, revert if below minimum amount requirement
        if (givenAmount < minBaseTokenAmount) {
            revert LiquoriceExecutor__AmountBelowMinimum();
        }
        // It is possible to have a quote with a smaller amount than was requested
        if (givenAmount > originalBaseTokenAmount) {
            return originalBaseTokenAmount;
        }
        return givenAmount;
    }

    /// @dev Modifies the filledTakerAmount in the liquorice calldata to handle slippage
    /// @param liquoriceCalldata The original calldata for the liquorice settlement
    /// @param givenAmount The actual amount available from the router
    /// @param partialFillOffset The offset from Liquorice API indicating where the fill amount is located
    /// @return The modified calldata with updated fill amount
    function _modifyFilledTakerAmount(
        bytes memory liquoriceCalldata,
        uint256 givenAmount,
        uint32 partialFillOffset
    ) internal pure returns (bytes memory) {
        // Use the offset from Liquorice API to locate the fill amount
        // Position = 4 bytes (selector) + offset bytes
        uint256 fillAmountPos = 4 + uint256(partialFillOffset);

        // Use assembly to modify the fill amount at the correct position
        // slither-disable-next-line assembly
        assembly {
            // Get pointer to the data portion of the bytes array
            let dataPtr := add(liquoriceCalldata, 0x20)

            // Calculate the actual position and store the new value
            let actualPos := add(dataPtr, fillAmountPos)
            mstore(actualPos, givenAmount)
        }

        return liquoriceCalldata;
    }

    /// @dev Returns the balance of a token or ETH for an account
    /// @param token The token address, or address(0) for ETH
    /// @param account The account to get the balance of
    /// @return The balance of the token or ETH for the account
    function _balanceOf(address token, address account)
        internal
        view
        returns (uint256)
    {
        return token == address(0)
            ? account.balance
            : IERC20(token).balanceOf(account);
    }

    /// @dev Allow receiving ETH for settlement calls that require ETH
    receive() external payable {}
}
