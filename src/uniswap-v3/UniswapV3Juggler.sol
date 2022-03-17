// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

/**
                ,oo
               (  ^)
                " "
                             ,oo
                            (  ^)
                             " "
       ,oo
      (  ^)                         ,oo
       " "                         (  ^)
                                    " "
                   (\___/)
        ,oo        \ (- -)       ,oo
       (  ^)       c\   >'      (  ^)
        " "          )D_/        " "
         \\|,    ____| |__    ,|//
           \ )  (  `  ~   )  ( /
            #\ / /| . ' .) \ /#
            | \ / )   , / \ / |
             \,/ ;;,,;,;   \,/
              _,#;,;;,;,
             /,i;;;,,;#,;
            //  %;;,;,;;,;
           ((    ;#;,;%;;,,
          _//     ;,;; ,#;,
         /_)      #,;    ))
                 //      \|_
                 \|_      |#\
                  |#\      -"
                   -"
 */

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";

import {FullMath} from "timeless/lib/FullMath.sol";

import {IQuoter} from "v3-periphery/interfaces/IQuoter.sol";

/// @title UniswapV3Juggler
/// @author zefram.eth
/// @notice Given xPYT/NYT input, computes how much to swap to result in
/// an equal amount of PYT & NYT.
/// @dev Used in conjunction with UniswapV3Swapper::swapNytToUnderlying() and
/// UniswapV3Swapper::swapXpytToUnderlying(). Should only be called offchain since
/// the gas cost is too high to be called onchain.
contract UniswapV3Juggler {
    /// -----------------------------------------------------------------------
    /// Constants
    /// -----------------------------------------------------------------------

    /// @dev The minimum value that can be returned from #getSqrtRatioAtTick + 1. Equivalent to getSqrtRatioAtTick(MIN_TICK) + 1
    /// Copied from v3-core/libraries/TickMath.sol
    uint160 internal constant MIN_SQRT_RATIO_PLUS_ONE = 4295128740;

    /// @dev The maximum value that can be returned from #getSqrtRatioAtTick - 1. Equivalent to getSqrtRatioAtTick(MAX_TICK) - 1
    /// Copied from v3-core/libraries/TickMath.sol
    uint160 internal constant MAX_SQRT_RATIO_MINUS_ONE =
        1461446703485210103287273052203988822378723970341;

    /// @dev The maximum number of binary search iterations to find swapAmountIn
    uint256 internal constant MAX_BINARY_SEARCH_ITERATIONS = 256;

    /// -----------------------------------------------------------------------
    /// Immutable parameters
    /// -----------------------------------------------------------------------

    /// @notice The official Uniswap V3 factory address
    address public immutable factory;

    /// @notice The Uniswap V3 Quoter deployment
    IQuoter public immutable quoter;

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------

    constructor(address factory_, IQuoter quoter_) {
        factory = factory_;
        quoter = quoter_;
    }

    /// -----------------------------------------------------------------------
    /// Juggle token inputs
    /// -----------------------------------------------------------------------

    /// @notice Given xPYT input, compute how much xPYT to swap into NYT to result in
    /// an equal amount of PYT & NYT.
    /// @param nyt The NYT contract
    /// @param xPYT The xPYT contract
    /// @param fee The fee tier of the Uniswap V3 pool to use
    /// @param tokenAmountIn The amount of token input
    /// @param maxError The maximum acceptable difference between the resulting PYT & NYT balances.
    /// Might not be achieved if MAX_BINARY_SEARCH_ITERATIONS is reached.
    /// @return swapAmountIn The amount of xPYT to swap into NYT
    function juggleXpytInput(
        ERC20 nyt,
        ERC4626 xPYT,
        uint24 fee,
        uint256 tokenAmountIn,
        uint256 maxError
    ) external returns (uint256 swapAmountIn) {
        bool zeroForOne = address(xPYT) < address(nyt);

        // do binary search to find swapAmountIn that balances the end state PYT/NYT amounts
        (uint256 lo, uint256 hi) = (0, tokenAmountIn);
        swapAmountIn = tokenAmountIn >> 1; // take initial guess
        uint256 i;
        while (i < MAX_BINARY_SEARCH_ITERATIONS) {
            uint256 tokenAmountOut = quoter.quoteExactInputSingle(
                address(xPYT),
                address(nyt),
                fee,
                swapAmountIn,
                zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE
            );
            uint256 endStateNYTBalance = tokenAmountOut;
            uint256 endStatePYTBalance = xPYT.convertToAssets(
                tokenAmountIn - swapAmountIn
            );
            if (endStatePYTBalance > endStateNYTBalance + maxError) {
                // end up with more PYT than NYT
                // swap more
                (lo, swapAmountIn, hi) = (
                    swapAmountIn,
                    (swapAmountIn + hi) >> 1,
                    hi
                );
            } else if (endStatePYTBalance + maxError < endStateNYTBalance) {
                // end up with more NYT than PYT
                // swap less
                (lo, swapAmountIn, hi) = (
                    lo,
                    (lo + swapAmountIn) >> 1,
                    swapAmountIn
                );
            } else {
                // end up with the same amount of NYT and NYT
                // return result
                return swapAmountIn;
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Given NYT input, compute how much NYT to swap into xPYT to result in
    /// an equal amount of PYT & NYT.
    /// @param nyt The NYT contract
    /// @param xPYT The xPYT contract
    /// @param fee The fee tier of the Uniswap V3 pool to use
    /// @param tokenAmountIn The amount of token input
    /// @param maxError The maximum acceptable difference between the resulting PYT & NYT balances.
    /// Might not be achieved if MAX_BINARY_SEARCH_ITERATIONS is reached.
    /// @return swapAmountIn The amount of NYT to swap into xPYT
    function juggleNytInput(
        ERC20 nyt,
        ERC4626 xPYT,
        uint24 fee,
        uint256 tokenAmountIn,
        uint256 maxError
    ) external returns (uint256 swapAmountIn) {
        bool zeroForOne = address(nyt) < address(xPYT);

        // do binary search to find swapAmountIn that balances the end state PYT/NYT amounts
        (uint256 lo, uint256 hi) = (0, tokenAmountIn);
        swapAmountIn = tokenAmountIn >> 1; // take initial guess
        uint256 i;
        while (i < MAX_BINARY_SEARCH_ITERATIONS) {
            uint256 tokenAmountOut = quoter.quoteExactInputSingle(
                address(nyt),
                address(xPYT),
                fee,
                swapAmountIn,
                zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE
            );
            uint256 endStateNYTBalance = tokenAmountIn - swapAmountIn;
            uint256 endStatePYTBalance = xPYT.convertToAssets(tokenAmountOut);
            if (endStatePYTBalance > endStateNYTBalance + maxError) {
                // end up with more PYT than NYT
                // swap less
                (lo, swapAmountIn, hi) = (
                    lo,
                    (lo + swapAmountIn) >> 1,
                    swapAmountIn
                );
            } else if (endStatePYTBalance + maxError < endStateNYTBalance) {
                // end up with more NYT than PYT
                // swap more
                (lo, swapAmountIn, hi) = (
                    swapAmountIn,
                    (swapAmountIn + hi) >> 1,
                    hi
                );
            } else {
                // end up with the same amount of NYT and NYT
                // return result
                return swapAmountIn;
            }
            unchecked {
                ++i;
            }
        }
    }
}
