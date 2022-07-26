// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import {WETH} from "solmate/tokens/WETH.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {Gate} from "timeless/Gate.sol";
import {IxPYT} from "timeless/external/IxPYT.sol";
import {BaseERC20} from "timeless/lib/BaseERC20.sol";

import {SafeCast} from "v3-core/libraries/SafeCast.sol";
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "v3-core/interfaces/callback/IUniswapV3SwapCallback.sol";

import {Swapper} from "../Swapper.sol";
import {PoolAddress} from "./lib/PoolAddress.sol";
import {ApproveMaxIfNeeded} from "../lib/ApproveMaxIfNeeded.sol";

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
    using ApproveMaxIfNeeded for ERC20;
    using ApproveMaxIfNeeded for IxPYT;

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
    /// @dev extraArg = (uint24 fee)
    /// fee: The fee tier of the Uniswap V3 pool to use
    function swapUnderlyingToNyt(SwapArgs calldata args)
        external
        payable
        virtual
        override
        nonReentrant
        returns (uint256 tokenAmountOut)
    {
        // check deadline
        if (block.timestamp > args.deadline) {
            revert Error_PastDeadline();
        }

        uint256 xPYTMinted;
        {
            // determine token input amount
            uint256 tokenAmountIn = args.useSwapperBalance
                ? args.underlying.balanceOf(address(this))
                : args.tokenAmountIn;

            // transfer underlying from sender
            if (!args.useSwapperBalance) {
                args.underlying.safeTransferFrom(
                    msg.sender,
                    address(this),
                    tokenAmountIn
                );
            }

            // take protocol fee
            ProtocolFeeInfo memory protocolFeeInfo_ = protocolFeeInfo;
            if (protocolFeeInfo_.fee > 0) {
                uint256 feeAmount = (tokenAmountIn * protocolFeeInfo_.fee) /
                    10000;
                if (feeAmount > 0) {
                    // deduct fee from token input
                    tokenAmountIn -= feeAmount;

                    // transfer fee to recipient
                    args.underlying.safeTransfer(
                        protocolFeeInfo_.recipient,
                        feeAmount
                    );
                }
            }

            // add token output from minting to result
            tokenAmountOut = tokenAmountIn;

            // use underlying to mint xPYT & NYT
            xPYTMinted = args.xPYT.previewDeposit(tokenAmountIn);
            args.underlying.approveMaxIfNeeded(
                address(args.gate),
                tokenAmountIn
            );
            args.gate.enterWithUnderlying(
                args.recipient, // nytRecipient
                address(this), // pytRecipient
                args.vault,
                args.xPYT,
                tokenAmountIn
            );
        }

        // swap xPYT to NYT
        {
            uint24 fee = abi.decode(args.extraArgs, (uint24));
            // swap and add swap output to result
            tokenAmountOut += _swap(
                args.xPYT,
                xPYTMinted,
                args.nyt,
                fee,
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
    function swapUnderlyingToXpyt(SwapArgs calldata args)
        external
        payable
        virtual
        override
        nonReentrant
        returns (uint256 tokenAmountOut)
    {
        // check deadline
        if (block.timestamp > args.deadline) {
            revert Error_PastDeadline();
        }

        uint256 tokenAmountIn;
        {
            // determine token input and output amounts
            tokenAmountIn = args.useSwapperBalance
                ? args.underlying.balanceOf(address(this))
                : args.tokenAmountIn;

            // transfer underlying from sender
            if (!args.useSwapperBalance) {
                args.underlying.safeTransferFrom(
                    msg.sender,
                    address(this),
                    tokenAmountIn
                );
            }

            // take protocol fee
            ProtocolFeeInfo memory protocolFeeInfo_ = protocolFeeInfo;
            if (protocolFeeInfo_.fee > 0) {
                uint256 feeAmount = (tokenAmountIn * protocolFeeInfo_.fee) /
                    10000;
                if (feeAmount > 0) {
                    // deduct fee from token input
                    tokenAmountIn -= feeAmount;

                    // transfer fee to recipient
                    args.underlying.safeTransfer(
                        protocolFeeInfo_.recipient,
                        feeAmount
                    );
                }
            }

            // add token output from minting to result
            tokenAmountOut = args.usePYT
                ? tokenAmountIn
                : args.xPYT.previewDeposit(tokenAmountIn);

            // use underlying to mint xPYT & NYT
            args.underlying.approveMaxIfNeeded(
                address(args.gate),
                tokenAmountIn
            );
            args.gate.enterWithUnderlying(
                address(this), // nytRecipient
                args.recipient, // pytRecipient
                args.vault,
                args.usePYT ? IxPYT(address(0)) : args.xPYT,
                tokenAmountIn
            );
        }

        // swap NYT to xPYT
        uint256 swapOutput;
        {
            uint24 fee = abi.decode(args.extraArgs, (uint24));
            swapOutput = _swap(
                args.nyt,
                tokenAmountIn,
                args.xPYT,
                fee,
                args.usePYT ? address(this) : args.recipient // set recipient to this when using PYT in order to unwrap xPYT
            );
        }

        // unwrap xPYT if necessary
        if (args.usePYT) {
            tokenAmountOut += args.xPYT.redeem(
                swapOutput,
                args.recipient,
                address(this)
            );
        } else {
            tokenAmountOut += swapOutput;
        }

        // check slippage
        if (tokenAmountOut < args.minAmountOut) {
            revert Error_InsufficientOutput();
        }
    }

    /// @inheritdoc Swapper
    /// @dev extraArg = (uint24 fee, uint256 swapAmountIn)
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
        // check deadline
        if (block.timestamp > args.deadline) {
            revert Error_PastDeadline();
        }

        // transfer token input from sender
        uint256 tokenAmountIn = args.tokenAmountIn;
        if (!args.useSwapperBalance) {
            args.nyt.safeTransferFrom(msg.sender, address(this), tokenAmountIn);
        }

        // take protocol fee
        ProtocolFeeInfo memory protocolFeeInfo_ = protocolFeeInfo;
        if (protocolFeeInfo_.fee > 0) {
            uint256 feeAmount = (tokenAmountIn * protocolFeeInfo_.fee) / 10000;
            if (feeAmount > 0) {
                // deduct fee from token input
                tokenAmountIn -= feeAmount;

                // transfer fee to recipient
                args.nyt.safeTransfer(protocolFeeInfo_.recipient, feeAmount);
            }
        }

        // swap NYT to xPYT
        uint256 swapAmountOut;
        uint256 swapAmountIn;
        {
            uint24 fee;
            (fee, swapAmountIn) = abi.decode(args.extraArgs, (uint24, uint256));
            swapAmountOut = _swap(
                args.nyt,
                swapAmountIn,
                args.xPYT,
                fee,
                address(this)
            );

            // convert swap output xPYT amount into equivalent PYT amount
            swapAmountOut = args.xPYT.convertToAssets(swapAmountOut);
        }

        // determine token output amount
        uint256 remainingAmountIn = args.useSwapperBalance
            ? args.nyt.balanceOf(address(this))
            : tokenAmountIn - swapAmountIn;
        if (remainingAmountIn < swapAmountOut) {
            // NYT to burn < PYT balance
            tokenAmountOut = remainingAmountIn;
        } else {
            // NYT balance >= PYT to burn
            tokenAmountOut = swapAmountOut;
        }

        // check slippage
        if (tokenAmountOut < args.minAmountOut) {
            revert Error_InsufficientOutput();
        }

        // burn xPYT & NYT into underlying
        args.xPYT.approveMaxIfNeeded(
            address(args.gate),
            args.xPYT.previewWithdraw(tokenAmountOut)
        );
        args.gate.exitToUnderlying(
            args.recipient,
            args.vault,
            args.xPYT,
            tokenAmountOut
        );

        // handle leftover tokens
        if (remainingAmountIn < swapAmountOut) {
            // NYT to burn < PYT balance
            // give leftover xPYT to recipient
            if (args.usePYT) {
                uint256 maxRedeemAmount = args.xPYT.maxRedeem(address(this));
                if (maxRedeemAmount != 0) {
                    args.xPYT.redeem(
                        args.xPYT.maxRedeem(address(this)),
                        args.recipient,
                        address(this)
                    );
                }
            } else {
                args.xPYT.safeTransfer(
                    args.recipient,
                    args.xPYT.balanceOf(address(this))
                );
            }
        } else {
            // NYT balance >= PYT to burn
            // give leftover NYT to recipient
            args.nyt.safeTransfer(
                args.recipient,
                args.nyt.balanceOf(address(this))
            );
        }
    }

    /// @inheritdoc Swapper
    /// @dev extraArg = (uint24 fee, uint256 swapAmountIn)
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
        // check deadline
        if (block.timestamp > args.deadline) {
            revert Error_PastDeadline();
        }

        // transfer token input from sender
        uint256 tokenAmountIn = args.tokenAmountIn;
        if (!args.useSwapperBalance) {
            if (args.usePYT) {
                // transfer PYT from sender to this
                args.pyt.safeTransferFrom(
                    msg.sender,
                    address(this),
                    tokenAmountIn
                );

                // convert PYT input into xPYT and update tokenAmountIn
                args.pyt.approveMaxIfNeeded(address(args.xPYT), tokenAmountIn);
                tokenAmountIn = args.xPYT.deposit(tokenAmountIn, address(this));
            } else {
                args.xPYT.safeTransferFrom(
                    msg.sender,
                    address(this),
                    tokenAmountIn
                );
            }
        }

        // take protocol fee
        ProtocolFeeInfo memory protocolFeeInfo_ = protocolFeeInfo;
        if (protocolFeeInfo_.fee > 0) {
            uint256 feeAmount = (tokenAmountIn * protocolFeeInfo_.fee) / 10000;
            if (feeAmount > 0) {
                // deduct fee from token input
                tokenAmountIn -= feeAmount;

                // transfer fee to recipient
                args.xPYT.safeTransfer(protocolFeeInfo_.recipient, feeAmount);
            }
        }

        // swap xPYT to NYT
        uint256 swapAmountOut;
        uint256 swapAmountIn;
        {
            uint24 fee;
            (fee, swapAmountIn) = abi.decode(args.extraArgs, (uint24, uint256));
            swapAmountOut = _swap(
                args.xPYT,
                swapAmountIn,
                args.nyt,
                fee,
                address(this)
            );
        }

        // determine token output amount
        uint256 remainingAmountIn = args.useSwapperBalance
            ? args.xPYT.balanceOf(address(this))
            : tokenAmountIn - swapAmountIn;
        // convert remainingAmountIn from xPYT amount to equivalent PYT amount
        remainingAmountIn = args.xPYT.previewRedeem(remainingAmountIn);
        if (remainingAmountIn < swapAmountOut) {
            // PYT to burn < NYT balance
            tokenAmountOut = remainingAmountIn;
        } else {
            // PYT balance >= NYT to burn
            tokenAmountOut = swapAmountOut;
        }

        // check slippage
        if (tokenAmountOut < args.minAmountOut) {
            revert Error_InsufficientOutput();
        }

        // burn xPYT & NYT into underlying
        args.xPYT.approveMaxIfNeeded(
            address(args.gate),
            args.xPYT.previewWithdraw(tokenAmountOut)
        );
        args.gate.exitToUnderlying(
            args.recipient,
            args.vault,
            args.xPYT,
            tokenAmountOut
        );

        // handle leftover tokens
        if (remainingAmountIn < swapAmountOut) {
            // PYT to burn < NYT balance
            // give leftover NYT to recipient
            args.nyt.safeTransfer(
                args.recipient,
                args.nyt.balanceOf(address(this))
            );
        } else {
            // PYT balance >= NYT to burn
            // give leftover xPYT to recipient
            if (args.usePYT) {
                uint256 maxRedeemAmount = args.xPYT.maxRedeem(address(this));
                if (maxRedeemAmount != 0) {
                    args.xPYT.redeem(
                        args.xPYT.maxRedeem(address(this)),
                        args.recipient,
                        address(this)
                    );
                }
            } else {
                args.xPYT.safeTransfer(
                    args.recipient,
                    args.xPYT.balanceOf(address(this))
                );
            }
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
    /// Internal utilities
    /// -----------------------------------------------------------------------

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
