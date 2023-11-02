// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {TickMath} from "./TickMath.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {SafeCast} from "lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";

contract UniV3Translator {
    // H/t: https://github.com/thanpolas/univ3prices
    // https://blog.uniswap.org/uniswap-v3-math-primer#relationship-between-tick-and-sqrtprice
    // https://github.com/Uniswap/v3-sdk/blob/08a7c050cba00377843497030f502c05982b1c43/src/utils/encodeSqrtRatioX96.ts

    // TODO: AmountIn for Tick (also return fees paid)

    // >>> 2**96 = 79228162514264337593543950336
    uint256 constant TWO_96 = 79228162514264337593543950336;

    // TODO: Get Price given Ratio

    /// @dev Given the X96SqrtPrice returns the Price
    function getRatioGivenSqrtPriceX96(uint160 ratioX192) external pure returns (uint256) {
        uint256 sqrtPrice = ratioX192 / TWO_96;
        return sqrtPrice * sqrtPrice;
        /// TODO: Should this be a numerator and denominator?
    }

    /// @dev Given 2 amounts, returns the X96SqrtPrice
    function getSqrtPriceX96GivenRatio(uint256 amount1, uint256 amount0) external pure returns (uint160) {
        // const numerator = JSBI.leftShift(JSBI.BigInt(amount1), JSBI.BigInt(192));
        uint256 numerator = amount1 << 192;
        // const denominator = JSBI.BigInt(amount0);
        uint256 denominator = amount0;
        // const ratioX192 = JSBI.divide(numerator, denominator);
        uint256 ratioX192 = numerator / denominator;

        return SafeCast.toUint160(Math.sqrt(ratioX192));
    }

    /// Given Tick return sqrtPriceX96
    function getSqrtRatioAtTick(int24 tick) external pure returns (uint160 price) {
        return TickMath.getSqrtRatioAtTick(tick);
    }

    /// Given sqrtPriceX96 return Tick (I think rounds up, NOT SURE | TODO)
    function getTickAtSqrtRatio(uint160 price) external pure returns (int24 tick) {
        return TickMath.getTickAtSqrtRatio(price);
    }
}
