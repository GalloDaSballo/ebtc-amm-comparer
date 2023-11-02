// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "./tERC20.sol";

// Token A
// Token B
// NOTE: Must be on OP FORK

// FACTORY
// https://optimistic.etherscan.io/address/0x2db0e83599a91b508ac268a6197b8b14f5e72840#code

/**
 * def deploy_plain_pool(
 *     _name: String[32],
 *     _symbol: String[10],
 *     _coins: address[4],
 *     _A: uint256,
 *     _fee: uint256,
 *     _asset_type: uint256 = 0, //     _asset_type Asset type for pool, as an integer  0 = USD, 1 = ETH, 2 = BTC, 3 = Other
 *     _implementation_idx: uint256 = 0,
 */
interface IFactory {
    function deploy_plain_pool(
        string memory name,
        string memory symbol,
        address[4] memory _coins,
        uint256 A,
        uint256 fee,
        uint256 assetType
    ) external returns (address);
}

interface IOracle {
    function latestAnswer() external view returns (uint256);
}

interface IPool {
    function add_liquidity(uint256[2] memory amounts, uint256 min_mint_amount) external returns (uint256);
    function add_liquidity(uint256[3] memory amounts, uint256 min_mint_amount) external returns (uint256);
    function add_liquidity(uint256[4] memory amounts, uint256 min_mint_amount) external returns (uint256);

    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function get_virtual_price() external view returns (uint256);
    function coins(uint256) external view returns (address);
    function balances(uint256) external view returns (uint256);
}

contract CurveStable is Test {
    uint256 MAX_BPS = 10_000;
    uint256 STABLE_FEES = 4000000;
    uint256 A = 5000;
    uint256 A_FOUR_POOL = 500;

    uint256 USD_TYPE = 0;
    uint256 ETH_TYPE = 1;
    uint256 BTC_TYPE = 2;
    uint256 OTHER_TYPE = 3;

    IFactory factory = IFactory(0x2db0E83599a91b508Ac268a6197b8B14F5e72840);

    address owner = address(123);

    function setUp() public {}

    function test_canDeploy() internal {
        tERC20 tokenA = new tERC20("A", "A", 18);
        tERC20 tokenB = new tERC20("B", "B", 18);

        address[4] memory tokens = [address(tokenA), address(tokenB), address(0), address(0)];

        factory.deploy_plain_pool("w/e", "WE", tokens, A, STABLE_FEES, BTC_TYPE);
    }

    function _setupNewTwoTokenPool(
        uint256 amountA,
        uint8 decimalsA,
        uint256 amountB,
        uint8 decimalsB,
        uint256 aValue,
        uint256 fees,
        uint256 poolType
    ) internal returns (address newPool, address firstToken, address secondToken) {
        // Deploy 2 mock tokens
        vm.startPrank(owner);
        tERC20 tokenA = new tERC20("A", "A", decimalsA);

        tERC20 tokenB = new tERC20("B", "B", decimalsB);

        address[4] memory tokens = [address(tokenA), address(tokenB), address(0), address(0)];

        newPool = factory.deploy_plain_pool("w/e", "WE", tokens, aValue, fees, poolType);

        tokenA.approve(newPool, amountA);
        tokenB.approve(newPool, amountB);

        uint256[2] memory amountsToAdd = [amountA, amountB];
        IPool(newPool).add_liquidity(amountsToAdd, 0);

        return (newPool, address(tokenA), address(tokenB));
    }


    function test_eBTC_wBTC() public {
        console2.log("Creating eBTC-wBTC Pool");
        uint256 EBTC_IN = 5_000e18;
        uint8 EBTC_DECIMALS = 18;

        uint256 WBTC_IN = 5_000e8;
        uint8 WBTC_DECIMALS = 8;

        // This is to adjust price
        // ORACLE for proper math
        // https://optimistic.etherscan.io/address/0xe59eba0d492ca53c6f46015eea00517f2707dc77#readContract
        IOracle oracle = IOracle(0xe59EBa0D492cA53C6f46015EEa00517F2707dc77);

        (address curvePool, address EBTC, address WBTC) =
            _setupNewTwoTokenPool(EBTC_IN, EBTC_DECIMALS, WBTC_IN, WBTC_DECIMALS, A, STABLE_FEES, BTC_TYPE);

        _showTheSwap(curvePool, 0, 1, 1e18, EBTC, WBTC);
        _showTheSwap(curvePool, 0, 1, 10e18, EBTC, WBTC);
        _showTheSwap(curvePool, 0, 1, 100e18, EBTC, WBTC);
        _showTheSwap(curvePool, 0, 1, 1_000e18, EBTC, WBTC);
        _showTheSwap(curvePool, 0, 1, 2_000e18, EBTC, WBTC);
        _showTheSwap(curvePool, 0, 1, 3_000e18, EBTC, WBTC);
        _showTheSwap(curvePool, 0, 1, 4_000e18, EBTC, WBTC);
        _showTheSwap(curvePool, 0, 1, 5_000e18, EBTC, WBTC);
        _showTheSwap(curvePool, 0, 1, 6_000e18, EBTC, WBTC);
        _showTheSwap(curvePool, 0, 1, 7_000e18, EBTC, WBTC);
        _showTheSwap(curvePool, 0, 1, 8_000e18, EBTC, WBTC);
        _showTheSwap(curvePool, 0, 1, 9_000e18, EBTC, WBTC);
        _showTheSwap(curvePool, 0, 1, 10_000e18, EBTC, WBTC);

        console2.log("");
        console2.log("");
        _showTheSwap(curvePool, 1, 0, 1e8, EBTC, WBTC);
        _showTheSwap(curvePool, 1, 0, 10e8, EBTC, WBTC);
        _showTheSwap(curvePool, 1, 0, 100e8, EBTC, WBTC);
        _showTheSwap(curvePool, 1, 0, 1_000e8, EBTC, WBTC);
        _showTheSwap(curvePool, 1, 0, 2_000e8, EBTC, WBTC);
        _showTheSwap(curvePool, 1, 0, 3_000e8, EBTC, WBTC);
        _showTheSwap(curvePool, 1, 0, 4_000e8, EBTC, WBTC);
        _showTheSwap(curvePool, 1, 0, 5_000e8, EBTC, WBTC);
        _showTheSwap(curvePool, 1, 0, 6_000e8, EBTC, WBTC);
        _showTheSwap(curvePool, 1, 0, 7_000e8, EBTC, WBTC);
        _showTheSwap(curvePool, 1, 0, 8_000e8, EBTC, WBTC);
        _showTheSwap(curvePool, 1, 0, 9_000e8, EBTC, WBTC);
        _showTheSwap(curvePool, 1, 0, 10_000e8, EBTC, WBTC);
    }

    function _showTheSwap(address pool, int128 i, int128 j, uint256 amtIn, address EBTC, address WBTC) internal {
        IPool asPool = IPool(pool);

        console2.log("");
        console2.log("");
        console2.log("amtIn", amtIn);
        console2.log("tokenIn", i == 0 ? "eBTC" : "wBTC");
        uint256 amtOut = asPool.get_dy(i, j, amtIn);
        console2.log("Amount Out", amtOut);

        console2.log("reserve i vs amtOut as %", asPool.balances(uint256(int256(j))) * 100 / amtOut);
    }



    function _addDecimals(uint256 value, uint256 decimals) internal pure returns (uint256) {
        return value * 10 ** decimals;
    }
}
