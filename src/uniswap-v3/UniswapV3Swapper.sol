// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import {WETH} from "solmate/tokens/WETH.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {IxPYT} from "timeless/external/IxPYT.sol";

import {SafeCast} from "v3-core/libraries/SafeCast.sol";
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "v3-core/interfaces/callback/IUniswapV3SwapCallback.sol";

import {Swapper} from "../Swapper.sol";
import {PoolAddress} from "./lib/PoolAddress.sol";

/// @title UniswapV3Swapper
/// @author zefram.eth
/// @notice Swapper that uses Uniswap V3 to swap between xPYTs/NYTs
contract UniswapV3Swapper is Swapper, IUniswapV3SwapCallback {
    /// -----------------------------------------------------------------------
    /// Library usage
    /// -----------------------------------------------------------------------

    using SafeCast for uint256;
    using SafeTransferLib for ERC20;
    using SafeTransferLib for IxPYT;

    /// -----------------------------------------------------------------------
    /// Errors
    /// -----------------------------------------------------------------------

    error Error_NotUniswapV3Pool();
    error Error_BothTokenDeltasAreZero();

    /// -----------------------------------------------------------------------
    /// Structs
    /// -----------------------------------------------------------------------

    struct SwapCallbackData {
        ERC20 tokenIn;
        ERC20 tokenOut;
        uint24 fee;
    }

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

    /// -----------------------------------------------------------------------
    /// Immutable parameters
    /// -----------------------------------------------------------------------

    /// @notice The official Uniswap V3 factory address
    address public immutable uniswapV3Factory;

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------

    constructor(
        address zeroExProxy_,
        WETH weth_,
        ProtocolFeeInfo memory protocolFeeInfo_,
        address uniswapV3Factory_
    ) Swapper(zeroExProxy_, weth_, protocolFeeInfo_) {
        uniswapV3Factory = uniswapV3Factory_;
    }

    /// -----------------------------------------------------------------------
    /// Swaps
    /// -----------------------------------------------------------------------

    /// @inheritdoc Swapper
    /// @dev extraArgs = (uint24 fee)
    /// fee: The fee tier of the Uniswap V3 pool to use
    function swapUnderlyingToNyt(SwapArgs calldata args)
        external
        payable
        virtual
        override
        nonReentrant
        returns (uint256 tokenAmountOut)
    {
        return _swapUnderlyingToNyt(args, abi.encode(args.nyt, args.extraArgs));
    }

    /// @inheritdoc Swapper
    /// @dev extraArgs = (uint24 fee)
    /// fee: The fee tier of the Uniswap V3 pool to use
    function swapUnderlyingToXpyt(SwapArgs calldata args)
        external
        payable
        virtual
        override
        nonReentrant
        returns (uint256 tokenAmountOut)
    {
        return
            _swapUnderlyingToXpyt(args, abi.encode(args.xPYT, args.extraArgs));
    }

    /// @inheritdoc Swapper
    /// @dev extraArgs = (uint24 fee, uint256 swapAmountIn)
    /// fee: The fee tier of the Uniswap V3 pool to use
    /// swapAmountIn: The amount of NYT to swap to xPYT
    function swapNytToUnderlying(SwapArgs calldata args)
        external
        payable
        virtual
        override
        nonReentrant
        returns (uint256 tokenAmountOut)
    {
        return
            _swapNytToUnderlying(args, abi.encode(args.xPYT, args.extraArgs));
    }

    /// @inheritdoc Swapper
    /// @dev extraArgs = (uint24 fee, uint256 swapAmountIn)
    /// fee: The fee tier of the Uniswap V3 pool to use
    /// swapAmountIn: The amount of xPYT to swap to NYT
    function swapXpytToUnderlying(SwapArgs calldata args)
        external
        payable
        virtual
        override
        nonReentrant
        returns (uint256 tokenAmountOut)
    {
        return
            _swapXpytToUnderlying(args, abi.encode(args.nyt, args.extraArgs));
    }

    /// -----------------------------------------------------------------------
    /// Uniswap V3 support
    /// -----------------------------------------------------------------------

    /// @inheritdoc IUniswapV3SwapCallback
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        // determine amount to pay
        uint256 amountToPay;
        if (amount0Delta > 0) {
            amountToPay = uint256(amount0Delta);
        } else if (amount1Delta > 0) {
            amountToPay = uint256(amount1Delta);
        } else {
            revert Error_BothTokenDeltasAreZero();
        }

        // decode callback data
        SwapCallbackData memory callbackData = abi.decode(
            data,
            (SwapCallbackData)
        );

        // verify sender
        address pool = PoolAddress.computeAddress(
            uniswapV3Factory,
            PoolAddress.getPoolKey(
                address(callbackData.tokenIn),
                address(callbackData.tokenOut),
                callbackData.fee
            )
        );
        if (msg.sender != address(pool)) {
            revert Error_NotUniswapV3Pool();
        }

        // pay tokens to the Uniswap V3 pool
        callbackData.tokenIn.safeTransfer(msg.sender, amountToPay);
    }

    /// -----------------------------------------------------------------------
    /// Internal functions
    /// -----------------------------------------------------------------------

    /// @inheritdoc Swapper
    /// @dev extraArgs = (ERC20 tokenOut, bytes swapExtraArgs)
    /// swapExtraArgs = (uint24 fee)
    /// tokenOut: The output token
    /// fee: The fee tier of the pool to use
    function _swapFromUnderlying(
        ERC20 tokenIn,
        uint256 tokenAmountIn,
        address recipient,
        bytes memory extraArgs
    ) internal virtual override returns (uint256 swapAmountOut) {
        // decode params
        (ERC20 tokenOut, bytes memory swapExtraArgs) = abi.decode(
            extraArgs,
            (ERC20, bytes)
        );
        uint24 fee = abi.decode(swapExtraArgs, (uint24));

        // perform swap
        return _swap(tokenIn, tokenAmountIn, tokenOut, fee, recipient);
    }

    /// @inheritdoc Swapper
    /// @dev extraArgs = (ERC20 tokenOut, bytes swapExtraArgs)
    /// swapExtraArgs = (uint24 fee, uint256 swapAmountIn)
    /// tokenOut: The output token
    /// fee: The fee tier of the pool to use
    /// swapAmountIn: The amount of tokenIn to swap
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
        (ERC20 tokenOut, bytes memory swapExtraArgs) = abi.decode(
            extraArgs,
            (ERC20, bytes)
        );
        uint24 fee;
        (fee, swapAmountIn) = abi.decode(swapExtraArgs, (uint24, uint256));

        // perform swap
        swapAmountOut = _swap(tokenIn, swapAmountIn, tokenOut, fee, recipient);
    }

    /// @dev Use a Uniswap V3 pool to swap between two tokens
    /// @param tokenIn The input token
    /// @param tokenAmountIn The token input amount
    /// @param tokenOut The output token
    /// @param fee The fee tier of the pool to use
    /// @param recipient The address that will receive the token output
    function _swap(
        ERC20 tokenIn,
        uint256 tokenAmountIn,
        ERC20 tokenOut,
        uint24 fee,
        address recipient
    ) internal returns (uint256) {
        // get uniswap v3 pool
        IUniswapV3Pool uniPool = IUniswapV3Pool(
            PoolAddress.computeAddress(
                uniswapV3Factory,
                PoolAddress.getPoolKey(address(tokenIn), address(tokenOut), fee)
            )
        );

        // do swap
        bytes memory swapCallbackData = abi.encode(
            SwapCallbackData({tokenIn: tokenIn, tokenOut: tokenOut, fee: fee})
        );
        bool zeroForOne = address(tokenIn) < address(tokenOut);
        (int256 amount0, int256 amount1) = uniPool.swap(
            recipient,
            zeroForOne,
            tokenAmountIn.toInt256(),
            zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE,
            swapCallbackData
        );

        return uint256(-(zeroForOne ? amount1 : amount0));
    }
}
