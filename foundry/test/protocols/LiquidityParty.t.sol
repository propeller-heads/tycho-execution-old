// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "../TestUtils.sol";
import "@src/executors/LiquidityPartyExecutor.sol";
import {Constants} from "../Constants.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract LiquidityPartyExecutorExposed is LiquidityPartyExecutor {
    constructor(address _permit2) LiquidityPartyExecutor(_permit2) {}

    function decodeParams(bytes calldata data)
        external
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
        return _decodeData(data);
    }
}

contract LiquidityPartyExecutorTest is Constants, TestUtils {
    using SafeERC20 for IERC20;

    LiquidityPartyExecutorExposed liquidityPartyExposed;
    IERC20 WETH = IERC20(WETH_ADDR);
    IERC20 USDC = IERC20(USDC_ADDR);
    IERC20 WBTC = IERC20(WBTC_ADDR);
    IERC20 USDT = IERC20(USDT_ADDR);
    IERC20 UNI = IERC20(0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984);
    IERC20 PEPE = IERC20(PEPE_ADDR);

    // LiquidityParty pool address
    address constant LIQUIDITY_PARTY_POOL =
        0xfA0be6148F66A6499666cf790d647D00daB76904;

    // Token indices in the pool
    uint8 constant USDT_INDEX = 0;
    uint8 constant USDC_INDEX = 1;
    uint8 constant WBTC_INDEX = 2;
    uint8 constant WETH_INDEX = 3;
    uint8 constant UNI_INDEX = 4;
    uint8 constant WSOL_INDEX = 5;
    uint8 constant TRX_INDEX = 6;
    uint8 constant AAVE_INDEX = 7;
    uint8 constant PEPE_INDEX = 8;
    uint8 constant SHIB_INDEX = 9;

    address constant WSOL_ADDR =
        address(0xD31a59c85aE9D8edEFeC411D448f90841571b89c);

    // Mock pool address for decode testing
    address constant MOCK_POOL =
        address(0x1234567890123456789012345678901234567890);

    function setUp() public {
        uint256 forkBlock = 24537169;
        vm.createSelectFork(vm.rpcUrl("mainnet"), forkBlock);
        liquidityPartyExposed =
            new LiquidityPartyExecutorExposed(PERMIT2_ADDRESS);
    }

    function testDecodeParams() public view {
        bytes memory params = abi.encodePacked(
            MOCK_POOL,
            WETH_ADDR,
            uint8(0),
            uint8(1),
            BOB,
            RestrictTransferFrom.TransferType.Transfer
        );

        (
            IPartyPool pool,
            address tokenIn,
            uint8 indexIn,
            uint8 indexOut,
            address receiver,
            RestrictTransferFrom.TransferType transferType
        ) = liquidityPartyExposed.decodeParams(params);

        assertEq(address(pool), MOCK_POOL);
        assertEq(tokenIn, WETH_ADDR);
        assertEq(indexIn, 0);
        assertEq(indexOut, 1);
        assertEq(receiver, BOB);
        assertEq(
            uint8(transferType),
            uint8(RestrictTransferFrom.TransferType.Transfer)
        );
    }

    function testDecodeParamsWithDifferentTransferType() public view {
        bytes memory params = abi.encodePacked(
            MOCK_POOL,
            USDC_ADDR,
            uint8(2),
            uint8(3),
            ALICE,
            RestrictTransferFrom.TransferType.None
        );

        (
            IPartyPool pool,
            address tokenIn,
            uint8 indexIn,
            uint8 indexOut,
            address receiver,
            RestrictTransferFrom.TransferType transferType
        ) = liquidityPartyExposed.decodeParams(params);

        assertEq(address(pool), MOCK_POOL);
        assertEq(tokenIn, USDC_ADDR);
        assertEq(indexIn, 2);
        assertEq(indexOut, 3);
        assertEq(receiver, ALICE);
        assertEq(
            uint8(transferType), uint8(RestrictTransferFrom.TransferType.None)
        );
    }

    function testDecodeParamsInvalidDataLength() public {
        // Data too short (only 40 bytes instead of 63)
        bytes memory invalidParams = abi.encodePacked(MOCK_POOL, WETH_ADDR);

        vm.expectRevert();
        liquidityPartyExposed.decodeParams(invalidParams);
    }

    function testDecodeParamsCorrectLength() public view {
        // Verify that exactly 63 bytes works correctly
        bytes memory params = abi.encodePacked(
            MOCK_POOL, // 20 bytes
            WETH_ADDR, // 20 bytes
            uint8(0), // 1 byte
            uint8(1), // 1 byte
            BOB, // 20 bytes
            RestrictTransferFrom.TransferType.Transfer // 1 byte
        );

        assertEq(params.length, 63);

        (
            IPartyPool pool,
            address tokenIn,
            uint8 indexIn,
            uint8 indexOut,
            address receiver,
            RestrictTransferFrom.TransferType transferType
        ) = liquidityPartyExposed.decodeParams(params);

        assertEq(address(pool), MOCK_POOL);
        assertEq(tokenIn, WETH_ADDR);
        assertEq(indexIn, 0);
        assertEq(indexOut, 1);
        assertEq(receiver, BOB);
        assertEq(
            uint8(transferType),
            uint8(RestrictTransferFrom.TransferType.Transfer)
        );
    }

    function testDecodeParamsAllTransferTypes() public view {
        RestrictTransferFrom.TransferType[3] memory transferTypes = [
            RestrictTransferFrom.TransferType.None,
            RestrictTransferFrom.TransferType.Transfer,
            RestrictTransferFrom.TransferType.TransferFrom
        ];

        for (uint256 i = 0; i < transferTypes.length; i++) {
            bytes memory params = abi.encodePacked(
                MOCK_POOL, WETH_ADDR, uint8(0), uint8(1), BOB, transferTypes[i]
            );

            (,,,,, RestrictTransferFrom.TransferType transferType) =
                liquidityPartyExposed.decodeParams(params);

            assertEq(uint8(transferType), uint8(transferTypes[i]));
        }
    }

    function testDecodeParamsWithRealPool() public view {
        bytes memory params = abi.encodePacked(
            LIQUIDITY_PARTY_POOL,
            WETH_ADDR,
            WETH_INDEX,
            USDC_INDEX,
            BOB,
            RestrictTransferFrom.TransferType.Transfer
        );

        (
            IPartyPool pool,
            address tokenIn,
            uint8 indexIn,
            uint8 indexOut,
            address receiver,
            RestrictTransferFrom.TransferType transferType
        ) = liquidityPartyExposed.decodeParams(params);

        assertEq(address(pool), LIQUIDITY_PARTY_POOL);
        assertEq(tokenIn, WETH_ADDR);
        assertEq(indexIn, WETH_INDEX);
        assertEq(indexOut, USDC_INDEX);
        assertEq(receiver, BOB);
        assertEq(
            uint8(transferType),
            uint8(RestrictTransferFrom.TransferType.Transfer)
        );
    }

    function testDecodeSwap() public {
        bytes memory protocolData =
            loadCallDataFromFile("test_encode_liquidityparty");
        uint256 amountIn = 1000000;
        uint256 amountOut = 4643054;
        deal(USDC_ADDR, address(liquidityPartyExposed), amountIn);
        liquidityPartyExposed.swap(amountIn, protocolData);

        // This receiver address must match the encoding in liquidity_party.rs test_encode_liquidityparty()
        uint256 finalBalance = IERC20(WSOL_ADDR)
            .balanceOf(address(0x1D96F2f6BeF1202E4Ce1Ff6Dad0c2CB002861d3e));
        assertGe(finalBalance, amountOut);
    }

    function testSwapWETHToUSDC() public {
        // Pool has only 7500705 [7.5e6] USDC available, use 0.001 ether to get ~3 USDC
        uint256 amountIn = 0.001 ether;
        bytes memory protocolData = abi.encodePacked(
            LIQUIDITY_PARTY_POOL,
            WETH_ADDR,
            WETH_INDEX,
            USDC_INDEX,
            BOB,
            RestrictTransferFrom.TransferType.Transfer
        );

        deal(WETH_ADDR, address(liquidityPartyExposed), amountIn);
        uint256 balanceBefore = USDC.balanceOf(BOB);

        uint256 amountOut = liquidityPartyExposed.swap(amountIn, protocolData);

        uint256 balanceAfter = USDC.balanceOf(BOB);
        assertGt(balanceAfter, balanceBefore);
        assertEq(balanceAfter - balanceBefore, amountOut);
        assertGt(amountOut, 0);
    }

    function testSwapUSDCToWETH() public {
        // Pool has 7500705 [7.5e6] USDC, use 5% = 375035
        uint256 amountIn = 375035;
        bytes memory protocolData = abi.encodePacked(
            LIQUIDITY_PARTY_POOL,
            USDC_ADDR,
            USDC_INDEX,
            WETH_INDEX,
            BOB,
            RestrictTransferFrom.TransferType.Transfer
        );

        deal(USDC_ADDR, address(liquidityPartyExposed), amountIn);
        uint256 balanceBefore = WETH.balanceOf(BOB);

        uint256 amountOut = liquidityPartyExposed.swap(amountIn, protocolData);

        uint256 balanceAfter = WETH.balanceOf(BOB);
        assertGt(balanceAfter, balanceBefore);
        assertEq(balanceAfter - balanceBefore, amountOut);
        assertGt(amountOut, 0);
    }

    function testSwapUSDTToUSDC() public {
        // Pool has 7431790 [7.431e6] USDT, use 5% = 371589
        uint256 amountIn = 371589;
        bytes memory protocolData = abi.encodePacked(
            LIQUIDITY_PARTY_POOL,
            USDT_ADDR,
            USDT_INDEX,
            USDC_INDEX,
            BOB,
            RestrictTransferFrom.TransferType.Transfer
        );

        deal(USDT_ADDR, address(liquidityPartyExposed), amountIn);
        uint256 balanceBefore = USDC.balanceOf(BOB);

        uint256 amountOut = liquidityPartyExposed.swap(amountIn, protocolData);

        uint256 balanceAfter = USDC.balanceOf(BOB);
        assertGt(balanceAfter, balanceBefore);
        assertEq(balanceAfter - balanceBefore, amountOut);
        assertGt(amountOut, 0);
    }

    function testSwapWBTCToWETH() public {
        // Pool has 11007 [1.1e4] WBTC (8 decimals), use 5% = 550
        uint256 amountIn = 550;
        bytes memory protocolData = abi.encodePacked(
            LIQUIDITY_PARTY_POOL,
            WBTC_ADDR,
            WBTC_INDEX,
            WETH_INDEX,
            BOB,
            RestrictTransferFrom.TransferType.Transfer
        );

        deal(WBTC_ADDR, address(liquidityPartyExposed), amountIn);
        uint256 balanceBefore = WETH.balanceOf(BOB);

        uint256 amountOut = liquidityPartyExposed.swap(amountIn, protocolData);

        uint256 balanceAfter = WETH.balanceOf(BOB);
        assertGt(balanceAfter, balanceBefore);
        assertEq(balanceAfter - balanceBefore, amountOut);
        assertGt(amountOut, 0);
    }

    function testSwapUNIToUSDC() public {
        // Pool has 1838224140769039670 [1.838e18] UNI, use 5% = 0.092 ether
        uint256 amountIn = 0.092 ether;
        bytes memory protocolData = abi.encodePacked(
            LIQUIDITY_PARTY_POOL,
            address(UNI),
            UNI_INDEX,
            USDC_INDEX,
            BOB,
            RestrictTransferFrom.TransferType.Transfer
        );

        deal(address(UNI), address(liquidityPartyExposed), amountIn);
        uint256 balanceBefore = USDC.balanceOf(BOB);

        uint256 amountOut = liquidityPartyExposed.swap(amountIn, protocolData);

        uint256 balanceAfter = USDC.balanceOf(BOB);
        assertGt(balanceAfter, balanceBefore);
        assertEq(balanceAfter - balanceBefore, amountOut);
        assertGt(amountOut, 0);
    }

    function testSwapPEPEToWETH() public {
        // Pool has 1777240401501820332402892 [1.777e24] PEPE, use 5% = 88862020075091016620144
        uint256 amountIn = 88862020075091016620144;
        bytes memory protocolData = abi.encodePacked(
            LIQUIDITY_PARTY_POOL,
            PEPE_ADDR,
            PEPE_INDEX,
            WETH_INDEX,
            BOB,
            RestrictTransferFrom.TransferType.Transfer
        );

        deal(PEPE_ADDR, address(liquidityPartyExposed), amountIn);
        uint256 balanceBefore = WETH.balanceOf(BOB);

        uint256 amountOut = liquidityPartyExposed.swap(amountIn, protocolData);

        uint256 balanceAfter = WETH.balanceOf(BOB);
        assertGt(balanceAfter, balanceBefore);
        assertEq(balanceAfter - balanceBefore, amountOut);
        assertGt(amountOut, 0);
    }

    function testSwapWithTransferTypeNone() public {
        // Pool has only 7500705 [7.5e6] USDC available, use 0.001 ether to get ~3 USDC
        uint256 amountIn = 0.001 ether;
        bytes memory protocolData = abi.encodePacked(
            LIQUIDITY_PARTY_POOL,
            WETH_ADDR,
            WETH_INDEX,
            USDC_INDEX,
            BOB,
            RestrictTransferFrom.TransferType.None
        );

        // Pre-fund the pool directly
        deal(WETH_ADDR, address(this), amountIn);
        IERC20(WETH_ADDR).transfer(LIQUIDITY_PARTY_POOL, amountIn);

        uint256 balanceBefore = USDC.balanceOf(BOB);

        uint256 amountOut = liquidityPartyExposed.swap(amountIn, protocolData);

        uint256 balanceAfter = USDC.balanceOf(BOB);
        assertGt(balanceAfter, balanceBefore);
        assertEq(balanceAfter - balanceBefore, amountOut);
        assertGt(amountOut, 0);
    }
}
