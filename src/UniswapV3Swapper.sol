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

/// @title UniswapV3Swapper
/// @author zefram.eth
/// @notice Swapper that uses Uniswap V3 to swap between xPYTs/NYTs
contract UniswapV3Swapper is Swapper, IUniswapV3SwapCallback, ReentrancyGuard {
    /// -----------------------------------------------------------------------
    /// Library usage
    /// -----------------------------------------------------------------------

    using SafeTransferLib for ERC20;
    using SafeTransferLib for ERC4626;

    /// -----------------------------------------------------------------------
    /// Errors
    /// -----------------------------------------------------------------------

    error Error_NotUniswapV3Pool();

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

    /// @notice The official Uniswap V3 factory address
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

    /// @inheritdoc Swapper
    /// @dev extraArg = (uint24 fee)
    /// fee: The fee tier of the Uniswap V3 pool to use
    function swapUnderlyingToXPYT(SwapArgs calldata args)
        external
        virtual
        override
        nonReentrant
        returns (uint256 tokenAmountOut)
    {
        // check deadline
        if (block.timestamp > args.deadline) {
            revert Error_PastDeadline();
        }

        ERC20 nyt;
        uint256 tokenAmountIn;
        {
            // fetch gate contracts
            Gate gate;
            address vault;
            {
                BaseERC20 pyt = BaseERC20(address(args.xPYT.asset()));
                gate = pyt.gate();
                vault = pyt.vault();
            }
            ERC20 underlying = gate.getUnderlyingOfVault(vault);
            nyt = ERC20(address(gate.getNegativeYieldTokenForVault(vault)));

            // determine token input and output amounts
            tokenAmountIn = args.useSwapperBalance
                ? underlying.balanceOf(address(this))
                : args.tokenAmountIn;
            tokenAmountOut = args.xPYT.previewDeposit(tokenAmountIn);

            // transfer underlying from sender
            if (!args.useSwapperBalance) {
                underlying.safeTransferFrom(
                    msg.sender,
                    address(this),
                    tokenAmountIn
                );
            }

            // use underlying to mint xPYT & NYT
            if (
                underlying.allowance(address(this), address(gate)) <
                tokenAmountIn
            ) {
                underlying.safeApprove(address(gate), type(uint256).max);
            }
            gate.enterWithUnderlying(
                address(this), // nytRecipient
                args.recipient, // pytRecipient
                vault,
                args.xPYT,
                tokenAmountIn
            );
        }

        // swap NYT to xPYT
        {
            uint24 fee = abi.decode(args.extraArgs, (uint24));
            tokenAmountOut += _swap(
                nyt,
                tokenAmountIn,
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

    /// @inheritdoc Swapper
    /// @dev extraArg = (uint24 fee)
    /// fee: The fee tier of the Uniswap V3 pool to use
    function swapUnderlyingToNYT(SwapArgs calldata args)
        external
        virtual
        override
        nonReentrant
        returns (uint256 tokenAmountOut)
    {
        // check deadline
        if (block.timestamp > args.deadline) {
            revert Error_PastDeadline();
        }

        ERC20 nyt;
        uint256 xPYTMinted;
        {
            // fetch gate contracts
            Gate gate;
            address vault;
            {
                BaseERC20 pyt = BaseERC20(address(args.xPYT.asset()));
                gate = pyt.gate();
                vault = pyt.vault();
            }
            ERC20 underlying = gate.getUnderlyingOfVault(vault);
            nyt = ERC20(address(gate.getNegativeYieldTokenForVault(vault)));

            // determine token input and output amounts
            uint256 tokenAmountIn = args.useSwapperBalance
                ? underlying.balanceOf(address(this))
                : args.tokenAmountIn;
            tokenAmountOut = tokenAmountIn;

            // transfer underlying from sender
            if (!args.useSwapperBalance) {
                underlying.safeTransferFrom(
                    msg.sender,
                    address(this),
                    tokenAmountIn
                );
            }

            // use underlying to mint xPYT & NYT
            xPYTMinted = args.xPYT.previewDeposit(tokenAmountIn);
            if (
                underlying.allowance(address(this), address(gate)) <
                tokenAmountIn
            ) {
                underlying.safeApprove(address(gate), type(uint256).max);
            }
            gate.enterWithUnderlying(
                args.recipient, // nytRecipient
                address(this), // pytRecipient
                vault,
                args.xPYT,
                tokenAmountIn
            );
        }

        // swap xPYT to NYT
        {
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

    /// @inheritdoc Swapper
    /// @dev extraArg = (uint24 fee, uint256 swapAmountIn)
    /// fee: The fee tier of the Uniswap V3 pool to use
    /// swapAmountIn: The amount of xPYT to swap to NYT
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

        // swap xPYT to NYT
        uint256 swapAmountOut;
        uint256 swapAmountIn;
        {
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

        // determine token output amount
        uint256 remainingAmountIn = args.useSwapperBalance
            ? args.xPYT.balanceOf(address(this))
            : args.tokenAmountIn - swapAmountIn;
        remainingAmountIn = args.xPYT.previewRedeem(remainingAmountIn); // convert remainingAmountIn from xPYT share amount to underlying amount
        if (remainingAmountIn < swapAmountOut) {
            // xPYT burnt < NYT balance
            tokenAmountOut = remainingAmountIn;
        } else {
            // xPYT balance >= NYT burnt
            tokenAmountOut = swapAmountOut;
        }

        // burn xPYT & NYT into underlying
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

    /// @inheritdoc Swapper
    /// @dev extraArg = (uint24 fee, uint256 swapAmountIn)
    /// fee: The fee tier of the Uniswap V3 pool to use
    /// swapAmountIn: The amount of NYT to swap to xPYT
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

        // swap NYT to xPYT
        uint256 swapAmountOut;
        uint256 swapAmountIn;
        {
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

        // determine token output amount
        uint256 remainingAmountIn = args.useSwapperBalance
            ? nyt.balanceOf(address(this))
            : args.tokenAmountIn - swapAmountIn;
        if (remainingAmountIn < swapAmountOut) {
            // NYT burnt < xPYT balance
            tokenAmountOut = remainingAmountIn;
        } else {
            // NYT balance >= xPYT burnt
            tokenAmountOut = swapAmountOut;
        }

        // burn xPYT & NYT into underlying
        if (
            args.xPYT.allowance(address(this), address(gate)) < tokenAmountOut
        ) {
            args.xPYT.safeApprove(address(gate), type(uint256).max);
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

    /// @inheritdoc IUniswapV3SwapCallback
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        require(amount0Delta > 0 || amount1Delta > 0); // swaps entirely within 0-liquidity regions are not supported

        // decode callback data
        SwapCallbackData memory callbackData = abi.decode(
            data,
            (SwapCallbackData)
        );
        (ERC20 tokenIn, ERC20 tokenOut) = (
            callbackData.tokenIn,
            callbackData.tokenOut
        );

        // verify sender
        address pool = PoolAddress.computeAddress(
            uniswapV3Factory,
            PoolAddress.getPoolKey(
                address(tokenIn),
                address(tokenOut),
                callbackData.fee
            )
        );
        if (msg.sender != address(pool)) {
            revert Error_NotUniswapV3Pool();
        }

        // pay tokens to the Uniswap V3 pool
        uint256 amountToPay = amount0Delta > 0
            ? uint256(amount0Delta)
            : uint256(amount1Delta);
        _pay(tokenIn, callbackData.payer, msg.sender, amountToPay);
    }

    /// -----------------------------------------------------------------------
    /// Internal utilities
    /// -----------------------------------------------------------------------

    /// @dev Use a Uniswap V3 pool to swap between two tokens
    /// @param tokenIn The input token
    /// @param tokenAmountIn The token input amount
    /// @param tokenOut The output token
    /// @param fee The fee tier of the pool to use
    /// @param payer The address that will pay the token input
    /// @param recipient The address that will receive the token output
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

    /// @dev Pays tokens to the recipient using the payer's balance
    /// @param token The token to pay
    /// @param payer The address that will pay the tokens
    /// @param recipient The address that will receive the tokens
    /// @param value The amount of tokens to pay
    function _pay(
        ERC20 token,
        address payer,
        address recipient,
        uint256 value
    ) internal {
        if (payer == address(this)) {
            // pay with tokens already in the contract
            token.safeTransfer(recipient, value);
        } else {
            // pull payment
            token.safeTransferFrom(payer, recipient, value);
        }
    }
}
