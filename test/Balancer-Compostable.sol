// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "./tERC20.sol";

/**
 * Note on Balancer work
 *     Due to extra complexity, we fork directly and perform the swaps
 *     This means we are just getting the spot liquidity values
 *     Tests will be less thorough, but they will demonstrate that we can match real values
 */

interface ICompostableFactory {
    function create(
        string memory name,
        string memory symbol,
        address[] memory tokens,
        uint256 amplificationParameter,
        address[] memory rateProviders,
        uint256[] memory tokenRateCacheDurations,
        bool exemptFromYieldProtocolFeeFlags,
        uint256 swapFeePercentage,
        address owner,
        bytes32 salt
    ) external returns (address);

    enum JoinKind {
        INIT,
        EXACT_TOKENS_IN_FOR_BPT_OUT,
        TOKEN_IN_FOR_EXACT_BPT_OUT,
        ALL_TOKENS_IN_FOR_EXACT_BPT_OUT
    }
}

interface IWeightedPoolFactory {
    function create(
        string memory name,
        string memory symbol,
        address[] memory tokens,
        uint256[] memory normalizedWeights,
        address[] memory rateProviders,
        uint256 swapFeePercentage,
        address owner,
        bytes32 salt
    ) external returns (address);

    enum JoinKind {
        INIT,
        EXACT_TOKENS_IN_FOR_BPT_OUT,
        TOKEN_IN_FOR_EXACT_BPT_OUT,
        ALL_TOKENS_IN_FOR_EXACT_BPT_OUT,
        ADD_TOKEN // for Managed Pool
    }
}
// Token A
// Token B
// Decimal A
// Decimal B
// Amount A
// AmountB
// RateA
// Rate B

// Rate provider for compostable
contract FakeRateProvider {
    uint256 public getRate = 1e18;

    constructor(uint256 newRate) {
        getRate = newRate;
    }
}

interface IPool {
    function getPoolId() external view returns (bytes32);
    function mint(address to) external returns (uint256 liquidity);
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);

    enum SwapKind {
        GIVEN_IN,
        GIVEN_OUT
    }

    struct BatchSwapStep {
        bytes32 poolId;
        uint256 assetInIndex;
        uint256 assetOutIndex;
        uint256 amount;
        bytes userData;
    }

    struct FundManagement {
        address sender;
        bool fromInternalBalance;
        address payable recipient;
        bool toInternalBalance;
    }

    function queryBatchSwap(
        SwapKind kind,
        BatchSwapStep[] memory swaps,
        address[] memory assets, // Note: same encoding
        FundManagement memory funds
    ) external returns (int256[] memory);

    function joinPool(bytes32 poolId, address sender, address recipient, JoinPoolRequest memory request)
        external
        payable;

    struct JoinPoolRequest {
        address[] assets;
        uint256[] maxAmountsIn;
        bytes userData;
        bool fromInternalBalance;
    }

    function getPoolTokens(bytes32 poolId)
        external
        view
        returns (address[] memory tokens, uint256[] memory balances, uint256 lastChangeBlock);
}

contract BalancerStable is Test {
    uint256 MAX_BPS = 10_000;

    ICompostableFactory compostableFactory = ICompostableFactory(0x043A2daD730d585C44FB79D2614F295D2d625412);
    IPool vault = IPool(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    address owner = address(123);

    function setUp() public {}

    struct TokensAndRates {
        uint256 amountA;
        uint8 decimalsA;
        uint256 amountB;
        uint8 decimalsB;
        uint256 rateA;
        uint256 rateB;
    }

    function _setupStablePool(TokensAndRates memory settings)
        internal
        returns (bytes32 poolId, address firstToken, address secondToken)
    {
        // Deploy 2 mock tokens
        vm.startPrank(owner);
        tERC20 tokenA = new tERC20("A", "A", settings.decimalsA);

        tERC20 tokenB = new tERC20("B", "B", settings.decimalsB);

        address newPool;
        {
            address[] memory tokens = new address[](2);
            tokens[0] = address(tokenA) > address(tokenB) ? address(tokenB) : address(tokenA);
            tokens[1] = address(tokenA) > address(tokenB) ? address(tokenA) : address(tokenB);

            address[] memory rates = new address[](2);
            rates[0] = address(0);
            rates[1] = address(0);

            uint256[] memory durations = new uint256[](2);
            durations[0] = 0;
            durations[1] = 0;


            // Deploy new pool
            newPool = compostableFactory.create(
                "Pool",
                "POOL",
                tokens,
                50,
                rates,
                durations,
                false,
                500000000000000,
                address(0xBA1BA1ba1BA1bA1bA1Ba1BA1ba1BA1bA1ba1ba1B),
                bytes32(0xa9b1420213d2145ac43d5d7334c4413d629350bd452d187a766ab8ad3d91ac75)
            );
        }

        poolId = IPool(newPool).getPoolId();

        (address[] memory setupPoolTokens,,) = vault.getPoolTokens(poolId);

        console2.log("setupPoolTokens", setupPoolTokens.length);
        console2.log("setupPoolTokens", setupPoolTokens[0]);
        console2.log("setupPoolTokens", setupPoolTokens[1]);
        console2.log("setupPoolTokens", setupPoolTokens[2]);
        {
            tokenA.approve(address(vault), settings.amountA);
            tokenB.approve(address(vault), settings.amountB);

            address[] memory assets = new address[](3);
            assets[0] = setupPoolTokens[0];
            assets[1] = setupPoolTokens[1];
            assets[2] = setupPoolTokens[2];

            uint256 MAX = 1e18;

            uint256[] memory MAX_AMOUNTS = new uint256[](3);
            MAX_AMOUNTS[0] = type(uint256).max;
            MAX_AMOUNTS[1] = type(uint256).max;
            MAX_AMOUNTS[2] = type(uint256).max;

            uint256[] memory amountsToAdd = new uint256[](3);
            amountsToAdd[0] = setupPoolTokens[0] == address(tokenA)
                ? settings.amountA
                : setupPoolTokens[0] == address(tokenB) ? settings.amountB : MAX;
            console2.log("amountsToAdd[0]", amountsToAdd[0]);

            amountsToAdd[1] = setupPoolTokens[1] == address(tokenA)
                ? settings.amountA
                : setupPoolTokens[1] == address(tokenB) ? settings.amountB : MAX;
            console2.log("amountsToAdd[1]", amountsToAdd[1]);

            amountsToAdd[2] = setupPoolTokens[2] == address(tokenA)
                ? settings.amountA
                : setupPoolTokens[2] == address(tokenB) ? settings.amountB : MAX;
            console2.log("amountsToAdd[2]", amountsToAdd[2]);

            // Abi encode of INIT VALUE
            // [THE 3 AMOUNTS we already wrote]

            // We are pranking owner so this is ok
            vault.joinPool(
                poolId,
                owner,
                owner,
                IPool.JoinPoolRequest(
                    assets, MAX_AMOUNTS, abi.encode(ICompostableFactory.JoinKind.INIT, amountsToAdd), false
                )
            );
        }

        (, uint256[] memory balancesAfterJoin,) = vault.getPoolTokens(poolId);

        for (uint256 i = 0; i < balancesAfterJoin.length; i++) {
            console2.log("balancesAfterJoin stable pool", balancesAfterJoin[i]);
        }

        vm.stopPrank();

        return (poolId, address(tokenA), address(tokenB));
    }

    uint256 constant EBTC_IN = 100e18; // 5e18 eBTC
    uint256 constant EBTC_TO_WBTC = 1e18; // 1 to 1


    function test_EBTC_WBTC_Compostable() public {
        // Assumption is we always swap
        
        uint256 WBTC_IN = EBTC_IN * EBTC_TO_WBTC / 1e18;

        uint256 RATE = 1e18;
        uint8 DECIMALS = 18;

        (bytes32 poolId, address EBTC, address WBTC) = _setupStablePool(
            TokensAndRates(
                EBTC_IN,
                DECIMALS,
                WBTC_IN,
                DECIMALS,
                RATE,
                RATE
            )
        );


        console2.log("");
        console2.log("");
        console2.log("From EBTC to WBTC (simmetric)");

        uint256 max = WBTC_IN * 3;
        uint256 step = WBTC_IN / 100;
        uint256 amt_in = step;
        while(amt_in < max) {
            console2.log("");
             _balSwap(poolId, owner, amt_in, EBTC, WBTC);
             amt_in += step;
        }
        


    }

    function _balSwap(bytes32 poolId, address user, uint256 amountIn, address tokenIn, address tokenOut)
        internal
        returns (uint256)
    {
        vm.startPrank(user);

        tERC20(tokenIn).approve(address(vault), amountIn);

        IPool.BatchSwapStep[] memory steps = new IPool.BatchSwapStep[](1);
        steps[0] = IPool.BatchSwapStep(
            poolId,
            0,
            1,
            amountIn,
            abi.encode("") // Empty user data
        );

        address[] memory tokens = new address[](2);
        tokens[0] = tokenIn;
        tokens[1] = tokenOut;

        console2.log("amountIn", amountIn);

        int256[] memory res = vault.queryBatchSwap(
            IPool.SwapKind.GIVEN_IN, steps, tokens, IPool.FundManagement(user, false, payable(user), false)
        );

        vm.stopPrank();

        // Negative means we receive those tokens
        if (res[1] > 0) {
            revert("invalid result");
        }

        uint256 amtOut = uint256(-res[1]);
        console2.log("AmountOut", amtOut);
        console2.log("Amt Out * 100 / Amt In", amtOut * 100 / amountIn);

        return amtOut;
    }

    function _addDecimals(uint256 value, uint256 decimals) internal pure returns (uint256) {
        return value * 10 ** decimals;
    }
}