// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

/**
                ,oo
               (  ^)
                " "
                             ,oo
                            (  ^)
                             " "
       ,oo        ┌ ─ ─ ─ ─ ─ ─           
      (  ^)         I <3 Curve │    ,oo
       " "        └ ─ ─ ─ ─ ─ ─    (  ^)
                             /      " "
                   (\___/)  /
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
import {ICurveCryptoSwap2ETH} from "./external/ICurveCryptoSwap2ETH.sol";

/// @title CurveV2Juggler
/// @author zefram.eth
/// @notice Given xPYT/NYT input, computes how much to swap to result in
/// an equal amount of PYT & NYT.
/// @dev Used in conjunction with CurveV2Swapper::swapNytToUnderlying() and
/// CurveV2Swapper::swapXpytToUnderlying(). Should only be called offchain since
/// the gas cost is too high to be called onchain.
/// Assumes for all Curve pools used, coins[0] is NYT and coins[1] is xPYT.
contract CurveV2Juggler {
    /// -----------------------------------------------------------------------
    /// Constants
    /// -----------------------------------------------------------------------

    /// @dev The maximum number of binary search iterations to find swapAmountIn
    uint256 internal constant MAX_BINARY_SEARCH_ITERATIONS = 256;

    /// -----------------------------------------------------------------------
    /// Juggle token inputs
    /// -----------------------------------------------------------------------

    /// @notice Given xPYT input, compute how much xPYT to swap into NYT to result in
    /// an equal amount of PYT & NYT.
    /// @param xPYT The xPYT contract
    /// @param pool The Curve V2 pool to use
    /// @param tokenAmountIn The amount of token input
    /// @param maxError The maximum acceptable difference between the resulting PYT & NYT balances.
    /// Might not be achieved if MAX_BINARY_SEARCH_ITERATIONS is reached.
    /// @return swapAmountIn The amount of xPYT to swap into NYT
    function juggleXpytInput(
        ERC4626 xPYT,
        ICurveCryptoSwap2ETH pool,
        uint256 tokenAmountIn,
        uint256 maxError
    ) external view returns (uint256 swapAmountIn) {
        // do binary search to find swapAmountIn that balances the end state PYT/NYT amounts
        (uint256 lo, uint256 hi) = (0, tokenAmountIn);
        swapAmountIn = tokenAmountIn >> 1; // take initial guess
        uint256 k;
        while (k < MAX_BINARY_SEARCH_ITERATIONS) {
            uint256 endStateNYTBalance = pool.get_dy(1, 0, swapAmountIn);
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
                ++k;
            }
        }
    }

    /// @notice Given NYT input, compute how much NYT to swap into xPYT to result in
    /// an equal amount of PYT & NYT.
    /// @param xPYT The xPYT contract
    /// @param pool The Curve V2 pool to use
    /// @param tokenAmountIn The amount of token input
    /// @param maxError The maximum acceptable difference between the resulting PYT & NYT balances.
    /// Might not be achieved if MAX_BINARY_SEARCH_ITERATIONS is reached.
    /// @return swapAmountIn The amount of NYT to swap into xPYT
    function juggleNytInput(
        ERC4626 xPYT,
        ICurveCryptoSwap2ETH pool,
        uint256 tokenAmountIn,
        uint256 maxError
    ) external view returns (uint256 swapAmountIn) {
        // do binary search to find swapAmountIn that balances the end state PYT/NYT amounts
        (uint256 lo, uint256 hi) = (0, tokenAmountIn);
        swapAmountIn = tokenAmountIn >> 1; // take initial guess
        uint256 k;
        while (k < MAX_BINARY_SEARCH_ITERATIONS) {
            uint256 tokenAmountOut = pool.get_dy(0, 1, swapAmountIn);
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
                ++k;
            }
        }
    }
}
