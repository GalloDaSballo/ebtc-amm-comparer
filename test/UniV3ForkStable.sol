// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import "./tERC20.sol";
import "src/UniV3Translator.sol";

interface IUnIV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);

    function initialize(uint160 sqrtPriceX96) external;

    struct Slot0 {
        // the current price
        uint160 sqrtPriceX96;
        // the current tick
        int24 tick;
        // the most-recently updated index of the observations array
        uint16 observationIndex;
        // the current maximum number of observations that are being stored
        uint16 observationCardinality;
        // the next maximum number of observations to store, triggered in observations.write
        uint16 observationCardinalityNext;
        // the current protocol fee as a percentage of the swap fee taken on withdrawal
        // represented as an integer denominator (1/x)%
        uint8 feeProtocol;
        // whether the pool is locked
        bool unlocked;
    }

    function slot0() external view returns (Slot0 memory);
    function liquidity() external view returns (uint128);
    function fee() external view returns (uint24);
}

interface IUniV3Factory {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

interface IV3NFTManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min; // w/e you have?
        uint256 amount1Min; // w/e you have?
        address recipient;
        uint256 deadline;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

interface IUniV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams memory params) external payable returns (uint256 amountOut);
}

contract UniV3ForkFixture is Test {
    // == NOTE: ONLY CHANGE BELOW HERE ==//
    // NOTE: Change this to change rest of settings
    // Run with: TODO

    uint256 constant EBTC_IN = 5_000e18; // 5e18 eBTC
    uint256 constant EBTC_TO_WBTC = 1e18; // 1 to 1
    int24 constant TICK_SPACING = 60; // Souce: Docs
    int24 constant TICK_RANGE_MULTIPLIER = 18; // 1.0001^1000 = around 10%, which is sloppy enough, for conc liquidity
    // 18 * 60 = 1080 so it's close to it

    // Given these we will calculate the amount of ETH
    // Then we set the price and the ticks
    // We LP and we simulate assuming a 50/50 LP ratio
    // == NOTE: ONLY CHANGE ABOVE HERE ==//
    
    address constant WHALE = address(0xb453d);

    uint24 constant DEFAULT_FEE = 3000;
    

    // Deploy new pool
    IUniV3Factory constant UNIV3_FACTORY = IUniV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);

    // Swap
    IUniV3Router constant UNIV3_SWAP_ROUTER_2 = IUniV3Router(0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45);

    // Add liquidity
    IV3NFTManager constant UNIV3_NFT_MANAGER = IV3NFTManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = -MIN_TICK;

    UniV3Translator translator;

    function setUp() public {
        translator = new UniV3Translator();
    }

    function _createNewPool(uint256 amountA, uint256 amountB, int24 multipleTicksA, int24 multipleTicksB)
        // TODO: Add some way to handle ticks
        internal
        returns (address newPool, address firstToken, address secondToken)
    {
        // Deploy 2 mock tokens
        vm.startPrank(WHALE);
        address tokenA = address(new tERC20("A", "A", 18));
        address tokenB = address(new tERC20("B", "B", 18));

        firstToken = tokenA > tokenB ? tokenB : tokenA;
        secondToken = tokenB > tokenB ? tokenB : tokenA;

        // Create the Pool
        newPool = UNIV3_FACTORY.createPool(firstToken, secondToken, DEFAULT_FEE);
        firstToken = IUnIV3Pool(newPool).token0();
        secondToken = IUnIV3Pool(newPool).token1();
        console2.log("newPool", newPool);

        uint256 firstAmount = firstToken == tokenA ? amountA : amountB;
        uint256 secondAmount = secondToken == tokenA ? amountA : amountB;

        // Initialize here
        // Use translator to find price
        // TODO: WHY???
        uint160 priceAtRatio = translator.getSqrtRatioAtTick(0);
        IUnIV3Pool(newPool).initialize(priceAtRatio);

        // LP here
        // SEE: https://polygonscan.com/tx/0xe7752f09e790e00f97bb04ba5e08a3d05bf936e78511713ed78301a39e563ad3
        // Approve the Manager
        tERC20(firstToken).approve(address(UNIV3_NFT_MANAGER), type(uint256).max);
        tERC20(secondToken).approve(address(UNIV3_NFT_MANAGER), type(uint256).max);

        tERC20(firstToken).approve(address(newPool), type(uint256).max);
        tERC20(secondToken).approve(address(newPool), type(uint256).max);
        {
            AddLiquidityParams memory addParams = AddLiquidityParams({
                pool: newPool,
                firstToken: firstToken,
                secondToken: secondToken,
                priceAtRatio: priceAtRatio,
                firstAmount: firstAmount,
                secondAmount: secondAmount,
                multipleTicksA: multipleTicksA,
                multipleTicksB: multipleTicksB
            });
            _addLiquidity(addParams);
        }

        vm.stopPrank();
        return (newPool, address(firstToken), address(secondToken));
    }

    struct AddLiquidityParams {
        address pool;
        address firstToken;
        address secondToken;
        uint160 priceAtRatio;
        uint256 firstAmount;
        uint256 secondAmount;
        int24 multipleTicksA;
        int24 multipleTicksB;
    }

    function _addLiquidity(AddLiquidityParams memory addParams) internal {
        // For ticks Lower we do: Tick of Price
        // For ticks Higher we do: Tick of Price
        {
            int24 targetTick = translator.getTickAtSqrtRatio(addParams.priceAtRatio);
            console2.log("targetTick", targetTick);

            int24 tickFromPool = (IUnIV3Pool(addParams.pool).slot0()).tick;
            console2.log("tickFromPool", tickFromPool);
            bool unlocked = (IUnIV3Pool(addParams.pool).slot0()).unlocked;
            console2.log("unlocked", unlocked);
            console2.log(
                "Current As Ratio", translator.getRatioGivenSqrtPriceX96(translator.getSqrtRatioAtTick(tickFromPool))
            );
        }

        {
            int24 tickFromPool = (IUnIV3Pool(addParams.pool).slot0()).tick;

            int24 tickLower = (
                translator.getTickAtSqrtRatio(addParams.priceAtRatio) - TICK_SPACING * addParams.multipleTicksA
            ) / TICK_SPACING * TICK_SPACING;
            int24 tickUpper = (
                translator.getTickAtSqrtRatio(addParams.priceAtRatio) + TICK_SPACING * addParams.multipleTicksB
            ) / TICK_SPACING * TICK_SPACING;

            console2.log("addParams.firstAmount", addParams.firstAmount);
            console2.log("addParams.secondAmount", addParams.secondAmount);

            // Mint
            IV3NFTManager.MintParams memory mintParams = IV3NFTManager.MintParams({
                token0: address(addParams.firstToken),
                token1: address(addParams.secondToken),
                fee: DEFAULT_FEE,
                tickLower: tickLower,
                tickUpper: tickUpper, // Not inclusive || // Does this forces to fees the other 59 ticks or not?
                amount0Desired: addParams.firstAmount,
                amount1Desired: addParams.secondAmount, // NOTE: Reverse due to something I must have messed up
                amount0Min: 0, // w/e you have?
                amount1Min: 0, // w/e you have?
                recipient: address(WHALE),
                deadline: block.timestamp
            });
            (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = UNIV3_NFT_MANAGER.mint(mintParams);
            console2.log("IUnIV3Pool(pool).liquidity()", IUnIV3Pool(addParams.pool).liquidity());
            console2.log("liquidity", liquidity);
            console2.log("tokenId", tokenId);
            console2.log("amount0", amount0);
            console2.log("amount1", amount1);
        }
    }

    function _swap(address pool, address tokenIn, address tokenOut, uint256 amountIn) internal {
        // Swap a bunch of times so fees raise
        vm.startPrank(WHALE);

        IERC20(tokenIn).approve(address(UNIV3_SWAP_ROUTER_2), type(uint256).max);

        // 0 is WETH
        IUniV3Router.ExactInputSingleParams memory inParams0 = IUniV3Router.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: IUnIV3Pool(pool).fee(),
            recipient: WHALE,
            amountIn: amountIn, // 0 means router uses w/e we sent
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = UNIV3_SWAP_ROUTER_2.exactInputSingle(inParams0);
        console2.log("");
        console2.log("");
        console2.log("Swap");
        console2.log("TokenIn", tokenIn);
        console2.log("amountIn", amountIn);
        console2.log("tokenOut", tokenOut);
        console2.log("amountOut", amountOut);
        vm.stopPrank();
    }

    function _swapAndRevert(address pool, address tokenIn, address tokenOut, uint256 amountIn) internal {
        uint256 snapshot = vm.snapshot();

        _swap(pool, tokenIn, tokenOut, amountIn);

        vm.revertTo(snapshot);
    }

    function testStableUniV3() public {
        vm.snapshot(); // add this here to avoid reverting to zero

        uint256 WBTC_IN = EBTC_IN * EBTC_TO_WBTC / 1e18; // Decimals
        console2.log("EBTC_IN", EBTC_IN);
        console2.log("WBTC_IN", WBTC_IN);

        // Deploy a Pool, with 1/1 LP in, and 1 tick left and 1 tick right from the middle
        (address newPool, address token0, address token1) = _createNewPool(WBTC_IN, EBTC_IN, TICK_RANGE_MULTIPLIER, TICK_RANGE_MULTIPLIER);

        int24 middleTick = (IUnIV3Pool(newPool).slot0()).tick / TICK_SPACING * TICK_SPACING; // Avoid non %

        console2.log("Original Ratio", translator.getRatioGivenSqrtPriceX96(translator.getSqrtRatioAtTick((IUnIV3Pool(newPool).slot0()).tick)));

        console2.log("");
        console2.log("## BEFORE ##");
        console2.log("token0", IERC20(token0).balanceOf(address(newPool)));
        console2.log("token1", IERC20(token1).balanceOf(address(newPool)));
        console2.log("tickFromPool", middleTick);

        // Swap Here
        // eBTC to wBTC
        _swapAndRevert(newPool, token0, token1, 100e18);
        _swapAndRevert(newPool, token0, token1, 1_000e18);
        _swapAndRevert(newPool, token0, token1, 2_000e18);
        _swapAndRevert(newPool, token0, token1, 5_000e18);
        _swapAndRevert(newPool, token0, token1, 10_000e18);

        // wBTC to eBTC
        _swapAndRevert(newPool, token1, token0, 100e18);
        _swapAndRevert(newPool, token1, token0, 1_000e18);
        _swapAndRevert(newPool, token1, token0, 2_000e18);
        _swapAndRevert(newPool, token1, token0, 5_000e18);
        _swapAndRevert(newPool, token1, token0, 10_000e18);
        _swapAndRevert(newPool, token1, token0, 100_000e18);


        // Determine Price from Tick0
        console2.log("Ratio", translator.getRatioGivenSqrtPriceX96(translator.getSqrtRatioAtTick((IUnIV3Pool(newPool).slot0()).tick)));
    }

}
