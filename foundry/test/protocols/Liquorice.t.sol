// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "../TestUtils.sol";
import "../TychoRouterTestSetup.sol";
import "@src/executors/LiquoriceExecutor.sol";
import {Constants} from "../Constants.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Permit2TestHelper} from "../Permit2TestHelper.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ILiquoriceSettlement {
    function BALANCE_MANAGER() external view returns (address);
    function AUTHENTICATOR() external view returns (address);
}

interface IAllowListAuthentication {
    function addSolver(address _solver) external;
    function addMaker(address _maker) external;
}

contract LiquoriceExecutorExposed is LiquoriceExecutor {
    constructor(
        address _liquoriceSettlement,
        address _liquoriceBalanceManager,
        address _permit2
    )
        LiquoriceExecutor(
            _liquoriceSettlement, _liquoriceBalanceManager, _permit2
        )
    {}

    function decodeData(bytes calldata data)
        external
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
        return _decodeData(data);
    }

    function clampAmount(
        uint256 givenAmount,
        uint256 originalBaseTokenAmount,
        uint256 minBaseTokenAmount
    ) external pure returns (uint256) {
        return _clampAmount(
            givenAmount, originalBaseTokenAmount, minBaseTokenAmount
        );
    }
}

contract LiquoriceExecutorTest is Constants, Permit2TestHelper, TestUtils {
    using SafeERC20 for IERC20;

    ILiquoriceSettlement liquoriceSettlement;
    IAllowListAuthentication authenticator;
    LiquoriceExecutorExposed liquoriceExecutor;

    address constant AUTH_MANAGER = 0x000438801500c89E225E8D6CB69D9c14dD05e000;

    IERC20 WETH = IERC20(WETH_ADDR);
    IERC20 USDC = IERC20(USDC_ADDR);
    IERC20 WBTC = IERC20(WBTC_ADDR);

    address constant MAKER = 0x06465bcEEaef280Bb7340A58D75dfc5E1F687058;
    uint256 constant FORK_BLOCK = 24_392_845;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK);

        liquoriceSettlement = ILiquoriceSettlement(LIQUORICE_SETTLEMENT);

        liquoriceExecutor = new LiquoriceExecutorExposed(
            LIQUORICE_SETTLEMENT, LIQUORICE_BALANCE_MANAGER, PERMIT2_ADDRESS
        );
        authenticator =
            IAllowListAuthentication(liquoriceSettlement.AUTHENTICATOR());

        vm.prank(AUTH_MANAGER);
        authenticator.addSolver(address(liquoriceExecutor));
        vm.prank(AUTH_MANAGER);
        authenticator.addMaker(MAKER);

        vm.prank(MAKER);
        WETH.approve(LIQUORICE_BALANCE_MANAGER, type(uint256).max);
    }

    function testSettleSingle() public {
        // 3000 USDC -> 1 WETH
        bytes memory liquoriceCalldata =
            hex"9935c86800000000000000000000000006465bceeaef280bb7340a58d75dfc5e1f68705800000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000024000000000000000000000000000000000000000000000000000000000b2d05e000000000000000000000000000000000000000000000000000000000000000320000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000000010000000000000000000000005615deb798bb3e4dfa0139dfa1b3d433cc23b72f0000000000000000000000005615deb798bb3e4dfa0139dfa1b3d433cc23b72f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc200000000000000000000000000000000000000000000000000000000b2d05e000000000000000000000000000000000000000000000000000de0b6b3a76400000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000006985036700000000000000000000000006465bceeaef280bb7340a58d75dfc5e1f687058000000000000000000000000000000000000000000000000000000000000000131000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000041883a6506193307eebda0f3adf2cb81f84a073e030749055ebb18cbf98704eef100a03c307266527d706f9a5c3e08ed0988f5b130bc5327e0ad62dde6f3709d251b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000";

        address tokenIn = USDC_ADDR;
        address tokenOut = WETH_ADDR;
        RestrictTransferFrom.TransferType transferType =
        RestrictTransferFrom.TransferType.None;
        uint32 partialFillOffset = 96; // PARTIAL_FILL_OFFSET_SETTLE_SINGLE_ORDER
        uint256 amountIn = 3000e6; // 3000 USDC
        bool approvalNeeded = true;
        uint256 expectedAmountOut = 1 ether;

        // Fund maker with WETH (what trader receives)
        deal(WETH_ADDR, MAKER, expectedAmountOut);
        // Fund executor with USDC (what trader sells)
        deal(tokenIn, address(liquoriceExecutor), amountIn);

        bytes memory params = abi.encodePacked(
            tokenIn,
            tokenOut,
            uint8(transferType),
            partialFillOffset,
            amountIn, // originalBaseTokenAmount
            amountIn, // minBaseTokenAmount (same for full fill)
            uint8(approvalNeeded ? 1 : 0),
            address(liquoriceExecutor),
            liquoriceCalldata
        );

        uint256 initialTokenOutBalance =
            IERC20(tokenOut).balanceOf(address(liquoriceExecutor));

        uint256 amountOut = liquoriceExecutor.swap(amountIn, params);

        assertEq(amountOut, expectedAmountOut, "Incorrect amount out");
        assertEq(
            IERC20(tokenOut).balanceOf(address(liquoriceExecutor))
                - initialTokenOutBalance,
            expectedAmountOut,
            "WETH should be at receiver"
        );
        assertEq(
            IERC20(tokenIn).balanceOf(address(liquoriceExecutor)),
            0,
            "USDC left in executor"
        );
    }

    function testSettleSingle_PartialFill() public {
        // 1500 USDC -> 0.5 WETH (50% partial fill of 3000 USDC -> 1 WETH quote)
        bytes memory liquoriceCalldata =
            hex"9935c86800000000000000000000000006465bceeaef280bb7340a58d75dfc5e1f68705800000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000024000000000000000000000000000000000000000000000000000000000b2d05e000000000000000000000000000000000000000000000000000000000000000320000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000000010000000000000000000000005615deb798bb3e4dfa0139dfa1b3d433cc23b72f0000000000000000000000005615deb798bb3e4dfa0139dfa1b3d433cc23b72f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc200000000000000000000000000000000000000000000000000000000b2d05e000000000000000000000000000000000000000000000000000de0b6b3a76400000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000006985036700000000000000000000000006465bceeaef280bb7340a58d75dfc5e1f687058000000000000000000000000000000000000000000000000000000000000000131000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000041883a6506193307eebda0f3adf2cb81f84a073e030749055ebb18cbf98704eef100a03c307266527d706f9a5c3e08ed0988f5b130bc5327e0ad62dde6f3709d251b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000";

        address tokenIn = USDC_ADDR;
        address tokenOut = WETH_ADDR;
        RestrictTransferFrom.TransferType transferType =
        RestrictTransferFrom.TransferType.None;
        uint32 partialFillOffset = 96; // PARTIAL_FILL_OFFSET_SETTLE_SINGLE_ORDER
        uint256 originalAmountIn = 3000e6; // Original quote: 3000 USDC
        uint256 amountIn = 1500e6; // Partial fill: 1500 USDC (50%)
        uint256 minAmountIn = 1500e6; // Minimum allowed
        bool approvalNeeded = true;
        uint256 expectedAmountOut = 0.5 ether; // 50% of 1 WETH

        // Fund maker with WETH (only need 0.5 for partial fill)
        deal(WETH_ADDR, MAKER, expectedAmountOut);
        // Fund executor with partial USDC amount
        deal(tokenIn, address(liquoriceExecutor), amountIn);

        bytes memory params = abi.encodePacked(
            tokenIn,
            tokenOut,
            uint8(transferType),
            partialFillOffset,
            originalAmountIn, // originalBaseTokenAmount from quote
            minAmountIn, // minBaseTokenAmount for partial fill
            uint8(approvalNeeded ? 1 : 0),
            address(liquoriceExecutor),
            liquoriceCalldata
        );

        uint256 initialTokenOutBalance =
            IERC20(tokenOut).balanceOf(address(liquoriceExecutor));

        uint256 amountOut = liquoriceExecutor.swap(amountIn, params);

        assertEq(amountOut, expectedAmountOut, "Incorrect partial amount out");
        assertEq(
            IERC20(tokenOut).balanceOf(address(liquoriceExecutor))
                - initialTokenOutBalance,
            expectedAmountOut,
            "WETH should be at receiver"
        );
        assertEq(
            IERC20(tokenIn).balanceOf(address(liquoriceExecutor)),
            0,
            "USDC left in executor"
        );
    }

    function testSettle() public {
        // 3000 USDC -> 1 WETH using settle() function
        bytes memory liquoriceCalldata =
            hex"cba673a700000000000000000000000006465bceeaef280bb7340a58d75dfc5e1f68705800000000000000000000000000000000000000000000000000000000b2d05e0000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000038000000000000000000000000000000000000000000000000000000000000003a0000000000000000000000000000000000000000000000000000000000000042000000000000000000000000000000000000000000000000000000000000005000000000000000000000000000448633eb8b0a42efed924c42069e0dcf08fb5520000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000026000000000000000000000000000000000000000000000000000000000000000010000000000000000000000005615deb798bb3e4dfa0139dfa1b3d433cc23b72f0000000000000000000000005615deb798bb3e4dfa0139dfa1b3d433cc23b72f000000000000000000000000000000000000000000000000000000006985036700000000000000000000000006465bceeaef280bb7340a58d75dfc5e1f6870580000000000000000000000000000000000000000000000000000000000000001000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4800000000000000000000000000000000000000000000000000000000b2d05e0000000000000000000000000000000000000000000000000000000000b2d05e0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000000000000000000000000000000000000000000000000de0b6b3a76400000000000000000000000000000000000000000000000000000de0b6b3a764000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000131000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000411d85c337d0e071eb601d8a90e2e8dd0afb61db200a1614c4afe5d26ff0c11bd402e018ab5fdbf8386437d7594af4383cf020a75c96e02c0a208f0b06e86115401b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000";

        address tokenIn = USDC_ADDR;
        address tokenOut = WETH_ADDR;
        RestrictTransferFrom.TransferType transferType =
        RestrictTransferFrom.TransferType.None;
        uint32 partialFillOffset = 32; // PARTIAL_FILL_OFFSET_SETTLE_ORDER
        uint256 amountIn = 3000e6; // 3000 USDC
        bool approvalNeeded = true;
        uint256 expectedAmountOut = 1 ether;

        // Fund maker with WETH
        deal(WETH_ADDR, MAKER, expectedAmountOut);
        // Fund executor with USDC
        deal(tokenIn, address(liquoriceExecutor), amountIn);

        bytes memory params = abi.encodePacked(
            tokenIn,
            tokenOut,
            uint8(transferType),
            partialFillOffset,
            amountIn, // originalBaseTokenAmount
            amountIn, // minBaseTokenAmount (same for full fill)
            uint8(approvalNeeded ? 1 : 0),
            address(liquoriceExecutor),
            liquoriceCalldata
        );

        uint256 initialTokenOutBalance =
            IERC20(tokenOut).balanceOf(address(liquoriceExecutor));

        uint256 amountOut = liquoriceExecutor.swap(amountIn, params);

        assertEq(amountOut, expectedAmountOut, "Incorrect amount out");
        assertEq(
            IERC20(tokenOut).balanceOf(address(liquoriceExecutor))
                - initialTokenOutBalance,
            expectedAmountOut,
            "WETH should be at receiver"
        );
        assertEq(
            IERC20(tokenIn).balanceOf(address(liquoriceExecutor)),
            0,
            "USDC left in executor"
        );
    }

    function testSettle_PartialFill() public {
        // 1500 USDC -> 0.5 WETH (50% partial fill) using settle() function
        bytes memory liquoriceCalldata =
            hex"cba673a700000000000000000000000006465bceeaef280bb7340a58d75dfc5e1f687058000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000038000000000000000000000000000000000000000000000000000000000000003a0000000000000000000000000000000000000000000000000000000000000042000000000000000000000000000000000000000000000000000000000000005000000000000000000000000000448633eb8b0a42efed924c42069e0dcf08fb5520000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000026000000000000000000000000000000000000000000000000000000000000000010000000000000000000000005615deb798bb3e4dfa0139dfa1b3d433cc23b72f0000000000000000000000005615deb798bb3e4dfa0139dfa1b3d433cc23b72f000000000000000000000000000000000000000000000000000000006985036700000000000000000000000006465bceeaef280bb7340a58d75dfc5e1f6870580000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4800000000000000000000000000000000000000000000000000000000b2d05e0000000000000000000000000000000000000000000000000000000000b2d05e0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000000000000000000000000000000000000000000000000de0b6b3a76400000000000000000000000000000000000000000000000000000de0b6b3a76400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000013100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000041e89ad636a6d749213b9339ac5218229adaa53bdf96d457ee2cebfd4fd02909bf678953c976ceca7307ef2e73c5687c33738a6a1e4130e378d220b68d9c59e18b1b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000";

        address tokenIn = USDC_ADDR;
        address tokenOut = WETH_ADDR;
        RestrictTransferFrom.TransferType transferType =
        RestrictTransferFrom.TransferType.None;
        uint32 partialFillOffset = 32; // PARTIAL_FILL_OFFSET_SETTLE_ORDER
        uint256 originalAmountIn = 3000e6; // Original quote: 3000 USDC
        uint256 amountIn = 1500e6; // Partial fill: 1500 USDC (50%)
        uint256 minAmountIn = 1500e6; // Minimum allowed
        bool approvalNeeded = true;
        uint256 expectedAmountOut = 0.5 ether; // 50% of 1 WETH

        // Fund maker with WETH (only need 0.5 for partial fill)
        deal(WETH_ADDR, MAKER, expectedAmountOut);
        // Fund executor with partial USDC amount
        deal(tokenIn, address(liquoriceExecutor), amountIn);

        bytes memory params = abi.encodePacked(
            tokenIn,
            tokenOut,
            uint8(transferType),
            partialFillOffset,
            originalAmountIn, // originalBaseTokenAmount from quote
            minAmountIn, // minBaseTokenAmount for partial fill
            uint8(approvalNeeded ? 1 : 0),
            address(liquoriceExecutor),
            liquoriceCalldata
        );

        uint256 initialTokenOutBalance =
            IERC20(tokenOut).balanceOf(address(liquoriceExecutor));

        uint256 amountOut = liquoriceExecutor.swap(amountIn, params);

        assertEq(amountOut, expectedAmountOut, "Incorrect partial amount out");
        assertEq(
            IERC20(tokenOut).balanceOf(address(liquoriceExecutor))
                - initialTokenOutBalance,
            expectedAmountOut,
            "WETH should be at receiver"
        );
        assertEq(
            IERC20(tokenIn).balanceOf(address(liquoriceExecutor)),
            0,
            "USDC left in executor"
        );
    }

    function testDecodeData() public view {
        bytes memory liquoriceCalldata = abi.encodePacked(
            bytes4(0xdeadbeef), // mock selector
            hex"1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
        );

        uint256 originalAmount = 1000000000; // 1000 USDC
        uint256 minAmount = 800000000; // 800 USDC
        address receiver = address(0xABcdEFABcdEFabcdEfAbCdefabcdeFABcDEFabCD);

        bytes memory params = abi.encodePacked(
            USDC_ADDR, // tokenIn (20 bytes)
            WETH_ADDR, // tokenOut (20 bytes)
            uint8(RestrictTransferFrom.TransferType.Transfer), // transferType (1 byte)
            uint32(5), // partialFillOffset (4 bytes)
            originalAmount, // originalBaseTokenAmount (32 bytes)
            minAmount, // minBaseTokenAmount (32 bytes)
            uint8(0), // approvalNeeded (1 byte) - false
            receiver, // receiver (20 bytes)
            liquoriceCalldata // variable length
        );

        (
            address decodedTokenIn,
            address decodedTokenOut,
            RestrictTransferFrom.TransferType decodedTransferType,
            uint32 decodedPartialFillOffset,
            uint256 decodedOriginalAmount,
            uint256 decodedMinAmount,
            bool decodedApprovalNeeded,
            address decodedReceiver,
            bytes memory decodedCalldata
        ) = liquoriceExecutor.decodeData(params);

        assertEq(decodedTokenIn, USDC_ADDR, "tokenIn mismatch");
        assertEq(decodedTokenOut, WETH_ADDR, "tokenOut mismatch");
        assertEq(
            uint8(decodedTransferType),
            uint8(RestrictTransferFrom.TransferType.Transfer),
            "transferType mismatch"
        );
        assertEq(decodedPartialFillOffset, 5, "partialFillOffset mismatch");
        assertEq(
            decodedOriginalAmount, originalAmount, "originalAmount mismatch"
        );
        assertEq(decodedMinAmount, minAmount, "minAmount mismatch");
        assertFalse(decodedApprovalNeeded, "approvalNeeded should be false");
        assertEq(decodedReceiver, receiver, "receiver mismatch");
        assertEq(
            keccak256(decodedCalldata),
            keccak256(liquoriceCalldata),
            "calldata mismatch"
        );
    }

    function testDecodeData_InvalidDataLength() public {
        // Too short - missing required fields
        bytes memory tooShort = abi.encodePacked(
            USDC_ADDR, // tokenIn (20 bytes)
            WETH_ADDR, // tokenOut (20 bytes)
            uint8(RestrictTransferFrom.TransferType.Transfer) // transferType (1 byte)
            // missing: partialFillOffset, originalAmount, approvalNeeded, receiver
        );

        vm.expectRevert(
            LiquoriceExecutor.LiquoriceExecutor__InvalidDataLength.selector
        );
        liquoriceExecutor.decodeData(tooShort);
    }

    function testClampAmount_WithinRange() public view {
        // givenAmount is within [minBaseTokenAmount, originalBaseTokenAmount]
        uint256 result = liquoriceExecutor.clampAmount(
            500, // givenAmount
            1000, // originalBaseTokenAmount
            100 // minBaseTokenAmount
        );
        assertEq(result, 500, "Should return givenAmount when within range");
    }

    function testClampAmount_ExceedsMax() public view {
        // givenAmount exceeds originalBaseTokenAmount
        uint256 result = liquoriceExecutor.clampAmount(
            1500, // givenAmount
            1000, // originalBaseTokenAmount
            100 // minBaseTokenAmount
        );
        assertEq(
            result,
            1000,
            "Should clamp to originalBaseTokenAmount when exceeded"
        );
    }

    function testClampAmount_BelowMin_Reverts() public {
        // givenAmount is below minBaseTokenAmount - should revert
        vm.expectRevert(
            LiquoriceExecutor.LiquoriceExecutor__AmountBelowMinimum.selector
        );
        liquoriceExecutor.clampAmount(
            50, // givenAmount
            1000, // originalBaseTokenAmount
            100 // minBaseTokenAmount
        );
    }
}

contract TychoRouterForLiquoriceTest is TychoRouterTestSetup {
    using SafeERC20 for IERC20;

    address constant AUTH_MANAGER = 0x000438801500c89E225E8D6CB69D9c14dD05e000;
    address constant MAKER = 0x06465bcEEaef280Bb7340A58D75dfc5E1F687058;

    // Override the fork block for Liquorice tests
    function getForkBlock() public pure override returns (uint256) {
        return 24392845;
    }

    function setUp() public override {
        super.setUp();

        // Whitelist executor as solver and MAKER
        ILiquoriceSettlement settlement =
            ILiquoriceSettlement(LIQUORICE_SETTLEMENT);
        IAllowListAuthentication authenticator =
            IAllowListAuthentication(settlement.AUTHENTICATOR());

        vm.prank(AUTH_MANAGER);
        authenticator.addSolver(address(tychoRouter));
        vm.prank(AUTH_MANAGER);
        authenticator.addMaker(MAKER);

        // MAKER approves balance manager
        vm.prank(MAKER);
        IERC20(WETH_ADDR).approve(LIQUORICE_BALANCE_MANAGER, type(uint256).max);
    }

    function testSettleSingleLiquoriceIntegration() public {
        // 3000 USDC -> 1 WETH using settleSingleOrder
        address user = 0xd2068e04Cf586f76EEcE7BA5bEB779D7bB1474A1;
        deal(USDC_ADDR, user, 3000e6);
        deal(WETH_ADDR, MAKER, 1 ether);
        uint256 expAmountOut = 1 ether;

        uint256 wethBefore = IERC20(WETH_ADDR).balanceOf(user);
        vm.startPrank(user);
        IERC20(USDC_ADDR).approve(tychoRouterAddr, type(uint256).max);

        bytes memory callData = loadCallDataFromFile(
            "test_single_encoding_strategy_liquorice_settle_single"
        );

        (bool success,) = tychoRouterAddr.call(callData);

        assertTrue(success, "Call Failed");
        uint256 wethReceived = IERC20(WETH_ADDR).balanceOf(user) - wethBefore;
        assertEq(wethReceived, expAmountOut, "Incorrect WETH received");
        assertEq(
            IERC20(USDC_ADDR).balanceOf(tychoRouterAddr),
            0,
            "USDC left in router"
        );
        vm.stopPrank();
    }

    function testSettleLiquoriceIntegration() public {
        // 3000 USDC -> 1 WETH using settle
        address user = 0xd2068e04Cf586f76EEcE7BA5bEB779D7bB1474A1;
        deal(USDC_ADDR, user, 3000e6);
        deal(WETH_ADDR, MAKER, 1 ether);
        uint256 expAmountOut = 1 ether;

        uint256 wethBefore = IERC20(WETH_ADDR).balanceOf(user);
        vm.startPrank(user);
        IERC20(USDC_ADDR).approve(tychoRouterAddr, type(uint256).max);

        bytes memory callData = loadCallDataFromFile(
            "test_single_encoding_strategy_liquorice_settle"
        );

        (bool success,) = tychoRouterAddr.call(callData);

        assertTrue(success, "Call Failed");
        uint256 wethReceived = IERC20(WETH_ADDR).balanceOf(user) - wethBefore;
        assertEq(wethReceived, expAmountOut, "Incorrect WETH received");
        assertEq(
            IERC20(USDC_ADDR).balanceOf(tychoRouterAddr),
            0,
            "USDC left in router"
        );
        vm.stopPrank();
    }
}
