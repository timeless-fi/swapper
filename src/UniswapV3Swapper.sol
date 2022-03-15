// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {ReentrancyGuard} from "solmate/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {Gate} from "timeless/Gate.sol";
import {BaseERC20} from "timeless/lib/BaseERC20.sol";

import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "v3-core/interfaces/callback/IUniswapV3SwapCallback.sol";

import {Swapper} from "./Swapper.sol";
import {PoolAddress} from "./lib/PoolAddress.sol";

contract UniswapV3Swapper is Swapper, IUniswapV3SwapCallback, ReentrancyGuard {
    /// -----------------------------------------------------------------------
    /// Library usage
    /// -----------------------------------------------------------------------

    using SafeTransferLib for ERC20;

    /// -----------------------------------------------------------------------
    /// Structs
    /// -----------------------------------------------------------------------

    struct SwapCallbackData {
        ERC20 tokenIn;
        ERC20 tokenOut;
        uint24 fee;
        address payer;
    }

    /// -----------------------------------------------------------------------
    /// Constants
    /// -----------------------------------------------------------------------

    /// @dev The minimum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MIN_TICK)
    /// Copied from v3-core/libraries/TickMath.sol
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;

    /// @dev The maximum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MAX_TICK)
    /// Copied from v3-core/libraries/TickMath.sol
    uint160 internal constant MAX_SQRT_RATIO =
        1461446703485210103287273052203988822378723970342;

    /// -----------------------------------------------------------------------
    /// Immutable parameters
    /// -----------------------------------------------------------------------

    address public immutable uniswapV3Factory;

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------

    constructor(address uniswapV3Factory_) {
        uniswapV3Factory = uniswapV3Factory_;
    }

    /// -----------------------------------------------------------------------
    /// Swaps
    /// -----------------------------------------------------------------------

    function swapUnderlyingToYieldToken(SwapArgs calldata args)
        external
        virtual
        override
        nonReentrant
        returns (uint256 tokenAmountOut)
    {
        // check deadline
        if (block.timestamp >= args.deadline) {
            revert Error_PastDeadline();
        }

        // fetch gate contracts
        ERC20 nyt;
        bool toXPYT;
        uint256 xPYTMinted;
        {
            Gate gate;
            address vault;
            {
                BaseERC20 pyt = BaseERC20(address(args.xPYT.asset()));
                gate = pyt.gate();
                vault = pyt.vault();
            }
            ERC20 underlying = gate.getUnderlyingOfVault(vault);
            nyt = ERC20(address(gate.getNegativeYieldTokenForVault(vault)));
            toXPYT = args.swapType == SwapType.XPYT;

            if (!args.useSwapperBalance) {
                // transfer underlying from sender
                underlying.safeTransferFrom(
                    msg.sender,
                    address(this),
                    args.tokenAmountIn
                );
            }

            // use underlying to mint xPYT & NYT
            xPYTMinted = args.xPYT.previewDeposit(args.tokenAmountIn);
            tokenAmountOut = toXPYT ? xPYTMinted : args.tokenAmountIn;
            if (
                underlying.allowance(address(this), address(gate)) <
                args.tokenAmountIn
            ) {
                underlying.safeApprove(address(gate), type(uint256).max);
            }
            gate.enterWithUnderlying(
                toXPYT ? address(this) : args.recipient, // nytRecipient
                toXPYT ? args.recipient : address(this), // pytRecipient
                vault,
                args.xPYT,
                args.tokenAmountIn
            );
        }

        // sell undesired side
        {
            // get uniswap v3 pool
            uint24 fee = abi.decode(args.extraArgs, (uint24));
            IUniswapV3Pool uniPool = IUniswapV3Pool(
                PoolAddress.computeAddress(
                    uniswapV3Factory,
                    PoolAddress.getPoolKey(
                        address(nyt),
                        address(args.xPYT),
                        fee
                    )
                )
            );

            // do swap
            ERC20 sellToken = toXPYT ? nyt : args.xPYT;
            ERC20 buyToken = toXPYT ? args.xPYT : nyt;
            bool zeroForOne = address(sellToken) < address(buyToken);
            (int256 amount0, int256 amount1) = uniPool.swap(
                args.recipient,
                zeroForOne,
                int256(toXPYT ? args.tokenAmountIn : xPYTMinted),
                zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
                abi.encode(
                    SwapCallbackData({
                        tokenIn: sellToken,
                        tokenOut: buyToken,
                        fee: fee,
                        payer: address(this)
                    })
                )
            );

            // add sell output to total output
            tokenAmountOut += uint256(-(zeroForOne ? amount1 : amount0));
        }

        // check slippage
        if (tokenAmountOut < args.minAmountOut) {
            revert Error_InsufficientOutput();
        }
    }

    function swapYieldTokenToUnderlying(SwapArgs calldata args)
        external
        virtual
        override
        nonReentrant
        returns (uint256 tokenAmountOut)
    {
        // check deadline
        if (block.timestamp >= args.deadline) {
            revert Error_PastDeadline();
        }

        // fetch gate contracts
        Gate gate;
        address vault;
        {
            BaseERC20 pyt = BaseERC20(address(args.xPYT.asset()));
            gate = pyt.gate();
            vault = pyt.vault();
        }
        ERC20 nyt = ERC20(address(gate.getNegativeYieldTokenForVault(vault)));
        bool fromXPYT = args.swapType == SwapType.XPYT;

        // buy the side we don't have
        uint256 swapAmountOut;
        uint256 swapAmountIn;
        {
            // get uniswap v3 pool
            uint24 fee;
            (fee, swapAmountIn) = abi.decode(args.extraArgs, (uint24, uint256));
            IUniswapV3Pool uniPool = IUniswapV3Pool(
                PoolAddress.computeAddress(
                    uniswapV3Factory,
                    PoolAddress.getPoolKey(
                        address(nyt),
                        address(args.xPYT),
                        fee
                    )
                )
            );

            // do swap
            ERC20 sellToken = fromXPYT ? args.xPYT : nyt;
            ERC20 buyToken = fromXPYT ? nyt : args.xPYT;
            bool zeroForOne = address(sellToken) < address(buyToken);
            (int256 amount0, int256 amount1) = uniPool.swap(
                address(this),
                zeroForOne,
                int256(swapAmountIn),
                zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
                abi.encode(
                    SwapCallbackData({
                        tokenIn: sellToken,
                        tokenOut: buyToken,
                        fee: fee,
                        payer: address(this)
                    })
                )
            );
            swapAmountOut = uint256(-(zeroForOne ? amount1 : amount0));
        }

        // burn xPYT & NYT into underlying
        uint256 remainingAmountIn = args.tokenAmountIn - swapAmountIn;
        if (fromXPYT) {
            // convert remainingAmountIn from xPYT share amount to underlying amount
            remainingAmountIn = args.xPYT.previewRedeem(remainingAmountIn);
        }
        if (remainingAmountIn < swapAmountOut) {
            // sell token < buy token
            tokenAmountOut = remainingAmountIn;
        } else {
            // sell token >= buy token
            tokenAmountOut = swapAmountOut;
        }
        gate.exitToUnderlying(args.recipient, vault, args.xPYT, tokenAmountOut);

        // handle leftover tokens
        if (remainingAmountIn < swapAmountOut) {
            // sell token < buy token
            // give leftover buy tokens to recipient
            ERC20 buyToken = fromXPYT ? nyt : args.xPYT;
            buyToken.safeTransfer(
                args.recipient,
                buyToken.balanceOf(address(this))
            );
        } else {
            // sell token >= buy token
            // give leftover sell tokens to recipient
            ERC20 sellToken = fromXPYT ? args.xPYT : nyt;
            sellToken.safeTransfer(
                args.recipient,
                sellToken.balanceOf(address(this))
            );
        }
    }

    /// -----------------------------------------------------------------------
    /// Uniswap V3 support
    /// -----------------------------------------------------------------------

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        require(amount0Delta > 0 || amount1Delta > 0); // swaps entirely within 0-liquidity regions are not supported

        SwapCallbackData memory callbackData = abi.decode(
            data,
            (SwapCallbackData)
        );
        (ERC20 tokenIn, ERC20 tokenOut) = (
            callbackData.tokenIn,
            callbackData.tokenOut
        );
        address pool = PoolAddress.computeAddress(
            uniswapV3Factory,
            PoolAddress.getPoolKey(
                address(tokenIn),
                address(tokenOut),
                callbackData.fee
            )
        );
        require(msg.sender == address(pool));

        uint256 amountToPay = amount0Delta > 0
            ? uint256(amount0Delta)
            : uint256(amount1Delta);
        _pay(tokenIn, callbackData.payer, msg.sender, amountToPay);
    }
}
