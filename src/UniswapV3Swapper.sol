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
    using SafeTransferLib for ERC4626;

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

    function swapUnderlyingToXPYT(SwapArgs calldata args)
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

            if (!args.useSwapperBalance) {
                // transfer underlying from sender
                underlying.safeTransferFrom(
                    msg.sender,
                    address(this),
                    args.tokenAmountIn
                );
            }

            // use underlying to mint xPYT & NYT
            tokenAmountOut = args.xPYT.previewDeposit(args.tokenAmountIn);
            if (
                underlying.allowance(address(this), address(gate)) <
                args.tokenAmountIn
            ) {
                underlying.safeApprove(address(gate), type(uint256).max);
            }
            gate.enterWithUnderlying(
                address(this), // nytRecipient
                args.recipient, // pytRecipient
                vault,
                args.xPYT,
                args.tokenAmountIn
            );
        }

        {
            // swap NYT to xPYT
            uint24 fee = abi.decode(args.extraArgs, (uint24));
            tokenAmountOut += _swap(
                nyt,
                args.tokenAmountIn,
                args.xPYT,
                fee,
                address(this),
                args.recipient
            );
        }

        // check slippage
        if (tokenAmountOut < args.minAmountOut) {
            revert Error_InsufficientOutput();
        }
    }

    function swapUnderlyingToNYT(SwapArgs calldata args)
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
            tokenAmountOut = args.tokenAmountIn;
            if (
                underlying.allowance(address(this), address(gate)) <
                args.tokenAmountIn
            ) {
                underlying.safeApprove(address(gate), type(uint256).max);
            }
            gate.enterWithUnderlying(
                args.recipient, // nytRecipient
                address(this), // pytRecipient
                vault,
                args.xPYT,
                args.tokenAmountIn
            );
        }

        {
            // swap xPYT to NYT
            uint24 fee = abi.decode(args.extraArgs, (uint24));
            tokenAmountOut += _swap(
                args.xPYT,
                xPYTMinted,
                nyt,
                fee,
                address(this),
                args.recipient
            );
        }

        // check slippage
        if (tokenAmountOut < args.minAmountOut) {
            revert Error_InsufficientOutput();
        }
    }

    function swapXPYTToUnderlying(SwapArgs calldata args)
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

        uint256 swapAmountOut;
        uint256 swapAmountIn;
        {
            // swap xPYT to NYT
            uint24 fee;
            (fee, swapAmountIn) = abi.decode(args.extraArgs, (uint24, uint256));
            swapAmountOut = _swap(
                args.xPYT,
                swapAmountIn,
                nyt,
                fee,
                msg.sender,
                address(this)
            );
        }

        // burn xPYT & NYT into underlying
        uint256 remainingAmountIn = args.tokenAmountIn - swapAmountIn;
        // convert remainingAmountIn from xPYT share amount to underlying amount
        remainingAmountIn = args.xPYT.previewRedeem(remainingAmountIn);
        if (remainingAmountIn < swapAmountOut) {
            // xPYT burnt < NYT balance
            tokenAmountOut = remainingAmountIn;
        } else {
            // xPYT balance >= NYT burnt
            tokenAmountOut = swapAmountOut;
        }
        gate.exitToUnderlying(args.recipient, vault, args.xPYT, tokenAmountOut);

        // handle leftover tokens
        if (remainingAmountIn < swapAmountOut) {
            // xPYT burnt < NYT balance
            // give leftover NYT to recipient
            nyt.safeTransfer(args.recipient, nyt.balanceOf(address(this)));
        } else {
            // xPYT balance >= NYT burnt
            // give leftover xPYT to recipient
            args.xPYT.safeTransfer(
                args.recipient,
                args.xPYT.balanceOf(address(this))
            );
        }
    }

    function swapNYTToUnderlying(SwapArgs calldata args)
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

        uint256 swapAmountOut;
        uint256 swapAmountIn;
        {
            // swap NYT to xPYT
            uint24 fee;
            (fee, swapAmountIn) = abi.decode(args.extraArgs, (uint24, uint256));
            swapAmountOut = _swap(
                nyt,
                swapAmountIn,
                args.xPYT,
                fee,
                msg.sender,
                address(this)
            );
        }

        // burn xPYT & NYT into underlying
        uint256 remainingAmountIn = args.tokenAmountIn - swapAmountIn;
        if (remainingAmountIn < swapAmountOut) {
            // NYT burnt < xPYT balance
            tokenAmountOut = remainingAmountIn;
        } else {
            // NYT balance >= xPYT burnt
            tokenAmountOut = swapAmountOut;
        }
        gate.exitToUnderlying(args.recipient, vault, args.xPYT, tokenAmountOut);

        // handle leftover tokens
        if (remainingAmountIn < swapAmountOut) {
            // NYT burnt < xPYT balance
            // give leftover xPYT to recipient
            args.xPYT.safeTransfer(
                args.recipient,
                args.xPYT.balanceOf(address(this))
            );
        } else {
            // NYT balance >= xPYT burnt
            // give leftover NYT to recipient
            nyt.safeTransfer(args.recipient, nyt.balanceOf(address(this)));
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

    /// -----------------------------------------------------------------------
    /// Internal utilities
    /// -----------------------------------------------------------------------

    function _swap(
        ERC20 tokenIn,
        uint256 tokenAmountIn,
        ERC20 tokenOut,
        uint24 fee,
        address payer,
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
            SwapCallbackData({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                payer: payer
            })
        );
        bool zeroForOne = address(tokenIn) < address(tokenOut);
        (int256 amount0, int256 amount1) = uniPool.swap(
            recipient,
            zeroForOne,
            int256(tokenAmountIn),
            zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
            swapCallbackData
        );

        return uint256(-(zeroForOne ? amount1 : amount0));
    }
}
