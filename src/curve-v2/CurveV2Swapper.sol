// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import {WETH} from "solmate/tokens/WETH.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {IxPYT} from "timeless/external/IxPYT.sol";

import {Swapper} from "../Swapper.sol";
import {ICurveCryptoSwap} from "./external/ICurveCryptoSwap.sol";
import {ApproveMaxIfNeeded} from "../lib/ApproveMaxIfNeeded.sol";

/// @title CurveV2Swapper
/// @author zefram.eth
/// @notice Swapper that uses Curve V2 to swap between xPYTs/NYTs
/// @dev Assumes for all Curve pools used, coins[0] is NYT and coins[1] is xPYT.
contract CurveV2Swapper is Swapper {
    /// -----------------------------------------------------------------------
    /// Library usage
    /// -----------------------------------------------------------------------

    using ApproveMaxIfNeeded for ERC20;

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------

    constructor(
        address zeroExProxy_,
        WETH weth_,
        ProtocolFeeInfo memory protocolFeeInfo_
    ) Swapper(zeroExProxy_, weth_, protocolFeeInfo_) {}

    /// -----------------------------------------------------------------------
    /// Swaps
    /// -----------------------------------------------------------------------

    /// @inheritdoc Swapper
    /// @dev extraArgs = (ICurveCryptoSwap pool)
    /// pool: The Curve v2 crypto pool to trade with
    function swapUnderlyingToNyt(SwapArgs calldata args)
        external
        payable
        virtual
        override
        nonReentrant
        returns (uint256 tokenAmountOut)
    {
        return _swapUnderlyingToNyt(args, abi.encode(1, 0, args.extraArgs));
    }

    /// @inheritdoc Swapper
    /// @dev extraArgs = (ICurveCryptoSwap pool)
    /// pool: The Curve v2 crypto pool to trade with
    function swapUnderlyingToXpyt(SwapArgs calldata args)
        external
        payable
        virtual
        override
        nonReentrant
        returns (uint256 tokenAmountOut)
    {
        return _swapUnderlyingToXpyt(args, abi.encode(0, 1, args.extraArgs));
    }

    /// @inheritdoc Swapper
    /// @dev extraArgs = (ICurveCryptoSwap pool, uint256 swapAmountIn)
    /// pool: The Curve v2 crypto pool to trade with
    /// swapAmountIn: The amount of NYT to swap to xPYT
    function swapNytToUnderlying(SwapArgs calldata args)
        external
        payable
        virtual
        override
        nonReentrant
        returns (uint256 tokenAmountOut)
    {
        return _swapNytToUnderlying(args, abi.encode(0, 1, args.extraArgs));
    }

    /// @inheritdoc Swapper
    /// @dev extraArgs = (ICurveCryptoSwap pool, uint256 swapAmountIn)
    /// pool: The Curve v2 crypto pool to trade with
    /// swapAmountIn: The amount of NYT to swap to xPYT
    function swapXpytToUnderlying(SwapArgs calldata args)
        external
        payable
        virtual
        override
        nonReentrant
        returns (uint256 tokenAmountOut)
    {
        return _swapXpytToUnderlying(args, abi.encode(1, 0, args.extraArgs));
    }

    /// -----------------------------------------------------------------------
    /// Internal functions
    /// -----------------------------------------------------------------------

    /// @inheritdoc Swapper
    /// @dev extraArgs = (uint256 i, uint256 j, bytes swapExtraArgs)
    /// swapExtraArgs = (ICurveCryptoSwap pool)
    /// i: The index of the input token in the Curve pool
    /// j: The index of the output token in the Curve pool
    /// pool: The Curve V2 pool to use
    function _swapFromUnderlying(
        ERC20 tokenIn,
        uint256 tokenAmountIn,
        address recipient,
        bytes memory extraArgs
    ) internal virtual override returns (uint256 swapAmountOut) {
        // decode params
        (uint256 i, uint256 j, bytes memory swapExtraArgs) = abi.decode(
            extraArgs,
            (uint256, uint256, bytes)
        );
        ICurveCryptoSwap pool = abi.decode(swapExtraArgs, (ICurveCryptoSwap));

        // perform swap
        tokenIn.approveMaxIfNeeded(address(pool), tokenAmountIn);
        return pool.exchange(i, j, tokenAmountIn, 0, false, recipient);
    }

    /// @inheritdoc Swapper
    /// @dev extraArgs = (uint256 i, uint256 j, bytes swapExtraArgs)
    /// swapExtraArgs = (ICurveCryptoSwap pool, uint256 swapAmountIn)
    /// i: The index of the input token in the Curve pool
    /// j: The index of the output token in the Curve pool
    /// pool: The Curve V2 pool to use
    /// swapAmountIn: The token input amount
    function _swapFromYieldToken(
        ERC20 tokenIn,
        address recipient,
        bytes memory extraArgs
    )
        internal
        virtual
        override
        returns (uint256 swapAmountIn, uint256 swapAmountOut)
    {
        // decode params
        (uint256 i, uint256 j, bytes memory swapExtraArgs) = abi.decode(
            extraArgs,
            (uint256, uint256, bytes)
        );
        ICurveCryptoSwap pool;
        (pool, swapAmountIn) = abi.decode(
            swapExtraArgs,
            (ICurveCryptoSwap, uint256)
        );

        // perform swap
        tokenIn.approveMaxIfNeeded(address(pool), swapAmountIn);

        swapAmountOut = pool.exchange(i, j, swapAmountIn, 0, false, recipient);
    }
}
