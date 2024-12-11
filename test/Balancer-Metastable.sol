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
interface IMetaStableFactory {
    function create(
        string memory name,
        string memory symbol,
        address[] memory tokens,
        uint256 amplificationParameter,
        address[] memory rateProviders,
        uint256[] memory priceRateCacheDuration,
        uint256 swapFeePercentage,
        bool oracleEnabled,
        address owner
    ) external returns (address);

    enum JoinKind {
        INIT,
        EXACT_TOKENS_IN_FOR_BPT_OUT,
        TOKEN_IN_FOR_EXACT_BPT_OUT
    }
    enum ExitKind {
        EXACT_BPT_IN_FOR_ONE_TOKEN_OUT,
        EXACT_BPT_IN_FOR_TOKENS_OUT,
        BPT_IN_FOR_EXACT_TOKENS_OUT
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
    function getRate() external view returns (uint256);

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

    function batchSwap(
        SwapKind kind,
        BatchSwapStep[] memory swaps,
        address[] memory assets,
        FundManagement memory funds,
        int256[] calldata limits,
        uint256 deadline
    ) external returns (int256[] memory assetDeltas);

    function joinPool(bytes32 poolId, address sender, address recipient, JoinPoolRequest memory request)
        external
        payable;

    struct JoinPoolRequest {
        address[] assets;
        uint256[] maxAmountsIn;
        bytes userData;
        bool fromInternalBalance;
    }

    function exitPool(bytes32 poolId, address sender, address recipient, ExitPoolRequest memory request) external;

    struct ExitPoolRequest {
        address[] assets;
        uint256[] minAmountsOut;
        bytes userData;
        bool toInternalBalance;
    }

    function getPoolTokens(bytes32 poolId)
        external
        view
        returns (address[] memory tokens, uint256[] memory balances, uint256 lastChangeBlock);
}

contract BalancerStable is Test {
    uint256 MAX_BPS = 10_000;

    IMetaStableFactory compostableFactory = IMetaStableFactory(0x67d27634E44793fE63c467035E31ea8635117cd4);
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
        returns (address pool, bytes32 poolId, address firstToken, address secondToken)
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

            tokenA = tERC20(tokens[0]);
            tokenB = tERC20(tokens[1]);

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
                50, // See: https://etherscan.io/address/0x1e19cf2d73a72ef1332c882f20534b6519be0276#readContract | NOTE: We cannot repro somehow
                rates,
                durations,
                400000000000000, // See: https://etherscan.io/address/0x1e19cf2d73a72ef1332c882f20534b6519be0276#readContract
                false,
                address(0)
            );
        }

        poolId = IPool(newPool).getPoolId();

        (address[] memory setupPoolTokens,,) = vault.getPoolTokens(poolId);

        console2.log("setupPoolTokens", setupPoolTokens.length);
        console2.log("setupPoolTokens", setupPoolTokens[0]);
        console2.log("setupPoolTokens", setupPoolTokens[1]);
        {
            tokenA.approve(address(vault), settings.amountA);
            tokenB.approve(address(vault), settings.amountB);

            address[] memory assets = new address[](2);
            assets[0] = setupPoolTokens[0];
            assets[1] = setupPoolTokens[1];

            uint256 MAX = 1e18;

            uint256[] memory MAX_AMOUNTS = new uint256[](2);
            MAX_AMOUNTS[0] = type(uint256).max;
            MAX_AMOUNTS[1] = type(uint256).max;

            uint256[] memory amountsToAdd = new uint256[](2);
            amountsToAdd[0] = setupPoolTokens[0] == address(tokenA) ? settings.amountA : settings.amountB;

            amountsToAdd[1] = setupPoolTokens[1] == address(tokenA) ? settings.amountA : settings.amountB;
            console2.log("amountsToAdd[1]", amountsToAdd[1]);

            // Abi encode of INIT VALUE
            // [THE 3 AMOUNTS we already wrote]

            // We are pranking owner so this is ok
            vault.joinPool(
                poolId,
                owner,
                owner,
                IPool.JoinPoolRequest(
                    assets, MAX_AMOUNTS, abi.encode(IMetaStableFactory.JoinKind.INIT, amountsToAdd), false
                )
            );

            // TODO: HOW DO WE REDUCE LIQ?
        }

        (, uint256[] memory balancesAfterJoin,) = vault.getPoolTokens(poolId);

        for (uint256 i = 0; i < balancesAfterJoin.length; i++) {
            console2.log("balancesAfterJoin stable pool", balancesAfterJoin[i]);
        }

        vm.stopPrank();

        return (newPool, poolId, address(tokenA), address(tokenB));
    }

    function test_weth_reth() public {
        // Assumption is we always swap

        // TODO: Go grab real pool
        uint256 WETH_IN = 1000e18;
        uint256 RETH_IN = 1000e18;

        // This will mint 1999999999999999000000 tokens (2k tokens basically)

        uint256 RATE = 1e18;
        uint8 DECIMALS = 18;

        // TODO: Compare with swaps and volume as well

        (address POOL, bytes32 poolId, address WETH, address RETH) =
            _setupStablePool(TokensAndRates(WETH_IN, DECIMALS, RETH_IN, DECIMALS, RATE, RATE));

        address[] memory assets = new address[](2);
        assets[0] = WETH;
        assets[1] = RETH;

        console2.log("");
        console2.log("");
        console2.log("From WETH to RETH (simmetric)");

        {
            console2.log("***0");
            _log_one_sided(POOL, poolId, assets, WETH, RETH);
            _log_multi_sided(POOL, poolId, assets, WETH, RETH);
        }

        uint256 max = WETH_IN * 3;
        uint256 step = WETH_IN / 100;
        uint256 amt_in = step;

        // NOTE: If we swap way too much we make the pool fully imbalanced
        uint256 iterations = 15;
        uint256 count = 0;
        while (count < iterations) {
            console2.log("");
            try this.balSwap(poolId, owner, amt_in, WETH, RETH) {
                amt_in += step;
            } catch {
                amt_in = max;
            }
            count++;
        }

        /// @audit if the swap is very imbalanced, it will not converge and you cannot single sided LP the tokens

        /// TODO: We should also try multi sided withdrawals

        console2.log("***1");
        _log_one_sided(POOL, poolId, assets, WETH, RETH);
        _log_multi_sided(POOL, poolId, assets, WETH, RETH);
    }

    function _log_one_sided(address POOL, bytes32 poolId, address[] memory assets, address WETH, address RETH) internal {
            uint256 remove0 = _bal_remove_liq_one_sided(poolId, assets, 1e18, 0, WETH);
            uint256 remove0_extensive = _bal_remove_liq_one_sided(poolId, assets, 1000e18, 0, WETH);
            uint256 remove1 = _bal_remove_liq_one_sided(poolId, assets, 1e18, 1, RETH);
            uint256 remove1_extensive = _bal_remove_liq_one_sided(poolId, assets, 1000e18, 1, RETH);

            console.log("remove0", remove0);
            console.log("remove0_extensive", remove0_extensive);
            console.log("remove1", remove1);
            console.log("remove1_extensive", remove1_extensive);
            console.log("IPool(POOL).getRate()", IPool(POOL).getRate());
    }

    function _log_multi_sided(address POOL, bytes32 poolId, address[] memory assets, address WETH, address RETH) internal {
        uint256[] memory res = _bal_remove_liq_all_sides(poolId, assets, 1e18);
        for(uint256 i; i < res.length; i++) {
            console.log("assets[i]", res[i]);
        }

        uint256[] memory res_2 = _bal_remove_liq_all_sides(poolId, assets, 1000e18);
        for(uint256 i; i < res_2.length; i++) {
            console.log("assets[i]", res_2[i]);
        }
    }

    function _bal_remove_liq_one_sided(
        bytes32 poolId,
        address[] memory assets,
        uint256 btpAmt,
        uint256 tokenOutIndex,
        address tokenToTrack
    ) internal returns (uint256) {
        uint256 snap = vm.snapshot();
        vm.startPrank(owner);

        uint256[] memory minAmountsOut = new uint256[](assets.length);

        /**
         * EXITS decoding
         *
         *         function exactBptInForTokenOut(bytes memory self) internal pure returns (uint256 bptAmountIn, uint256 tokenIndex) {
         *             (, bptAmountIn, tokenIndex) = abi.decode(self, (StablePool.ExitKind, uint256, uint256));
         *         }
         *
         *         function exactBptInForTokensOut(bytes memory self) internal pure returns (uint256 bptAmountIn) {
         *             (, bptAmountIn) = abi.decode(self, (StablePool.ExitKind, uint256));
         *         }
         */
        uint256 balB4 = IERC20(tokenToTrack).balanceOf(owner);
        vault.exitPool(
            poolId,
            owner,
            owner,
            IPool.ExitPoolRequest(
                assets,
                minAmountsOut,
                abi.encode(IMetaStableFactory.ExitKind.EXACT_BPT_IN_FOR_ONE_TOKEN_OUT, btpAmt, tokenOutIndex),
                false
            )
        );

        uint256 balAfter = IERC20(tokenToTrack).balanceOf(owner);
        // Alterantively withdraw 100% and see the result as well

        vm.stopPrank();
        vm.revertTo(snap);

        return balAfter - balB4;
    }

    function _bal_remove_liq_all_sides(
        bytes32 poolId,
        address[] memory assets,
        uint256 btpAmt
    ) internal returns (uint256[] memory) {
        uint256 snap = vm.snapshot();
        vm.startPrank(owner);

        uint256[] memory minAmountsOut = new uint256[](assets.length);

        /**
         * EXITS decoding
         *
         *         function exactBptInForTokenOut(bytes memory self) internal pure returns (uint256 bptAmountIn, uint256 tokenIndex) {
         *             (, bptAmountIn, tokenIndex) = abi.decode(self, (StablePool.ExitKind, uint256, uint256));
         *         }
         *
         *         function exactBptInForTokensOut(bytes memory self) internal pure returns (uint256 bptAmountIn) {
         *             (, bptAmountIn) = abi.decode(self, (StablePool.ExitKind, uint256));
         *         }
         */

        uint256[] memory balancesB4 = new uint256[](assets.length);

        for(uint256 i; i < assets.length; i++) {
            balancesB4[i] = IERC20(assets[i]).balanceOf(address(owner));
        }

        vault.exitPool(
            poolId,
            owner,
            owner,
            IPool.ExitPoolRequest(
                assets,
                minAmountsOut,
                abi.encode(IMetaStableFactory.ExitKind.EXACT_BPT_IN_FOR_TOKENS_OUT, btpAmt),
                false
            )
        );

        uint256[] memory deltaBalsAfter = new uint256[](assets.length);

        for(uint256 i; i < assets.length; i++) {
            deltaBalsAfter[i] = IERC20(assets[i]).balanceOf(address(owner)) - balancesB4[i];
        }

        // Alterantively withdraw 100% and see the result as well

        vm.stopPrank();
        vm.revertTo(snap);

        return deltaBalsAfter;
    }


    /// Setup to be called externally to catch reverts
    function balSwap(bytes32 poolId, address user, uint256 amountIn, address tokenIn, address tokenOut) external returns (uint256) {
        return _balSwap(poolId, user, amountIn, tokenIn, tokenOut);
    }

    // TODO: We should change this to be a real swap to simulate imbalanced pools
    // Since technically the asset can be imbalance
    // And that may affect the profitability of various operations
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

        int256[] memory limits = new int256[](2);
        limits[0] = type(int256).max;
        limits[1] = type(int256).max;

        int256[] memory res = vault.batchSwap(
            IPool.SwapKind.GIVEN_IN, steps, tokens, IPool.FundManagement(user, false, payable(user), false), limits, block.timestamp
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
