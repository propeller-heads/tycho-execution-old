// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IExecutor} from "../../interfaces/IExecutor.sol";
import {RestrictTransferFrom} from "../RestrictTransferFrom.sol";

contract LiquidityPartyExecutor is IExecutor, RestrictTransferFrom {
    constructor(address _permit2) RestrictTransferFrom(_permit2) {}

    /// @dev We avoid declaring any IERC20 types, since it is critical to use the router's transfer facility and never
    /// the inherent ERC20 transfer methods, not even the SafeERC20 versions.
    function swap(uint256 givenAmount, bytes calldata data)
        external
        payable
        returns (uint256 calculatedAmount)
    {
        // Decode swap data
        (
            IPartyPool pool,
            address tokenIn,
            uint8 indexIn,
            uint8 indexOut,
            address receiver,
            TransferType transferType
        ) = _decodeData(data);

        // This require is redundant, since it is already checked in our DEX code.
        // require(receiver != address(0), 'LiqP executor: No receiver');

        // Pre-fund the pool with the input token
        // NOTE: This approach only supports exact-in swaps that have no unused input.
        // Since Tycho does not currently support user-approves-pool, we cannot use
        // the preferred approach of giving allowances. Furthermore, the callback
        // funding technique costs about 18,000 gas more than prefunding. Therefore,
        // we prefund the pool with the desired max amount and allow there to be a
        // small amount of unrefunded input dust if the full input is not used. In
        // general, this will be cheaper than paying the additional gas for a refund
        // of unused input.
        _transfer(address(pool), transferType, tokenIn, givenAmount);

        // Perform the swap
        // slither-disable-next-line unused-return
        (
            // We ignore the actual amount in and allow there to be input dust.
            /*uint256 amountIn*/,
            uint256 amountOut,
            /*uint256 inFee*/
        ) = pool.swap(
            address(0), // payer address is unused if prefunding
            Funding.PREFUNDING,
            receiver,
            indexIn,
            indexOut,
            givenAmount,
            0, // no limit price
            0, // no deadline
            false, // no unwrap
            "" // no callback data
        );

        // calculatedAmount is the net output amount
        return amountOut;
    }

    function _decodeData(bytes calldata data)
        internal
        pure
        returns (
            IPartyPool pool,
            address tokenIn,
            uint8 indexIn,
            uint8 indexOut,
            address receiver,
            TransferType transferType
        )
    {
        // Do we really need this require? The decoding will revert if the length < 63 due to out-of-bounds array access
        // It will also revert if the pool address is not a LiquidityParty IPartyPool instance
        // It will also revert if the tokenIn address is not a token
        // It will also revert if either indexIn or indexOut is greater than numTokens
        // It will also revert if the transferType is not a valid enum
        //require(data.length == 63, 'LiqP executor: Invalid encoding');
        pool = IPartyPool(address(bytes20(data[0:20])));
        tokenIn = address(bytes20(data[20:40]));
        indexIn = uint8(data[40]);
        indexOut = uint8(data[41]);
        receiver = address(bytes20(data[42:62]));
        transferType = TransferType(uint8(data[62]));
    }
}

library Funding {
    /// @notice a constant passed to swap as the fundingSelector to indicate that the payer has used regular ERC20 approvals to allow the pool to move the necessary input tokens.
    // Slither analysis of this line is literally wrong and broken. The extra zero digits are REQUIRED by Solidity since it is a bytes4 literal.
    // slither-disable-next-line too-many-digits
    bytes4 internal constant APPROVALS = 0x00000000;

    /// @notice a constant passed to swap as the fundingSelector to indicate that the payer has already sent sufficient input tokens to the pool before calling swap, so no movement of input tokens is required.
    // Slither analysis of this line is literally wrong and broken. The extra zero digits are REQUIRED by Solidity since it is a bytes4 literal.
    // slither-disable-next-line too-many-digits
    bytes4 internal constant PREFUNDING = 0x00000001;
}

interface IPartyPool {
    /// @notice Protocol fee ledger accessor. Returns tokens owed (raw uint token units) from this pool as protocol fees
    ///         that have not yet been transferred out.
    function allProtocolFeesOwed() external view returns (uint256[] memory);

    /// @notice Swap input token inputTokenIndex -> token outputTokenIndex. Payer must approve token inputTokenIndex.
    /// @dev This function transfers the exact gross input (including fee) from payer and sends the computed output to receiver.
    ///      Non-standard tokens (fee-on-transfer, rebasers) are rejected via balance checks.
    /// @param payer address of the account that pays for the swap
    /// @param fundingSelector If set to USE_APPROVALS, then the payer must use regular ERC20 approvals to authorize the pool to move the required input amount. If this fundingSelector is USE_PREFUNDING, then all of the input amount is expected to have already been sent to the pool and no additional transfers are needed. Refunds of excess input amount are NOT provided and it is illegal to use this funding method with a limit price. Otherwise, for any other fundingSelector value, a callback style funding mechanism is used where the given selector is invoked on the payer, passing the arguments of (address inputToken, uint256 inputAmount). The callback function must send the given amount of input coin to the pool in order to continue the swap transaction, otherwise "Insufficient funds" is thrown.
    /// @param receiver address that will receive the output tokens
    /// @param inputTokenIndex index of input asset
    /// @param outputTokenIndex index of output asset
    /// @param maxAmountIn maximum amount of token inputTokenIndex (uint256) to transfer in (inclusive of fees)
    /// @param limitPrice maximum acceptable marginal price (64.64 fixed point). Pass 0 to ignore.
    /// @param deadline timestamp after which the transaction will revert. Pass 0 to ignore.
    /// @param cbData callback data if fundingSelector is of the callback type.
    /// @return amountIn actual input used (uint256), amountOut actual output sent (uint256), inFee fee taken from the input (uint256)
    function swap(
        address payer,
        bytes4 fundingSelector,
        address receiver,
        uint256 inputTokenIndex,
        uint256 outputTokenIndex,
        uint256 maxAmountIn,
        int128 limitPrice,
        uint256 deadline,
        bool unwrap,
        bytes memory cbData
    )
        external
        payable
        returns (uint256 amountIn, uint256 amountOut, uint256 inFee);
}
