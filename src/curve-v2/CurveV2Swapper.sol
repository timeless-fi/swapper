// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import {WETH} from "solmate/tokens/WETH.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {Gate} from "timeless/Gate.sol";
import {IxPYT} from "timeless/external/IxPYT.sol";
import {BaseERC20} from "timeless/lib/BaseERC20.sol";

import {Swapper} from "../Swapper.sol";
import {ICurveCryptoSwap} from "./external/ICurveCryptoSwap.sol";
import {ApproveMaxIfNeeded} from "../lib/ApproveMaxIfNeeded.sol";

/// @title CurveV2Swapper
/// @author zefram.eth
/// @notice Swapper that uses Curve V2 to swap between xPYTs/NYTs
contract CurveV2Swapper is Swapper {
    /// -----------------------------------------------------------------------
    /// Library usage
    /// -----------------------------------------------------------------------

    using SafeTransferLib for ERC20;
    using SafeTransferLib for IxPYT;
    using ApproveMaxIfNeeded for ERC20;
    using ApproveMaxIfNeeded for IxPYT;

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
    /// @dev extraArg = (address pool, uint256 i, uint256 j)
    /// pool: The Curve v2 crypto pool to trade with
    /// i: The index of the input token in the Curve pool
    /// j: The index of the output token in the Curve pool
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
            (ICurveCryptoSwap pool, uint256 i, uint256 j) = abi.decode(
                args.extraArgs,
                (ICurveCryptoSwap, uint256, uint256)
            );
            // swap and add swap output to result
            tokenAmountOut += _swap(
                args.xPYT,
                xPYTMinted,
                pool,
                i,
                j,
                args.recipient
            );
        }

        // check slippage
        if (tokenAmountOut < args.minAmountOut) {
            revert Error_InsufficientOutput();
        }
    }

    /// @inheritdoc Swapper
    /// @dev extraArg = (address pool, uint256 i, uint256 j)
    /// pool: The Curve v2 crypto pool to trade with
    /// i: The index of the input token in the Curve pool
    /// j: The index of the output token in the Curve pool
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
            (ICurveCryptoSwap pool, uint256 i, uint256 j) = abi.decode(
                args.extraArgs,
                (ICurveCryptoSwap, uint256, uint256)
            );
            swapOutput = _swap(
                args.nyt,
                tokenAmountIn,
                pool,
                i,
                j,
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
    /// @dev extraArg = (address pool, uint256 i, uint256 j, uint256 swapAmountIn)
    /// pool: The Curve v2 crypto pool to trade with
    /// i: The index of the input token in the Curve pool
    /// j: The index of the output token in the Curve pool
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
            ICurveCryptoSwap pool;
            uint256 i;
            uint256 j;
            (pool, i, j, swapAmountIn) = abi.decode(
                args.extraArgs,
                (ICurveCryptoSwap, uint256, uint256, uint256)
            );
            swapAmountOut = _swap(
                args.nyt,
                swapAmountIn,
                pool,
                i,
                j,
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
    /// @dev extraArg = (address pool, uint256 i, uint256 j, uint256 swapAmountIn)
    /// pool: The Curve v2 crypto pool to trade with
    /// i: The index of the input token in the Curve pool
    /// j: The index of the output token in the Curve pool
    /// swapAmountIn: The amount of NYT to swap to xPYT
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
            ICurveCryptoSwap pool;
            uint256 i;
            uint256 j;
            (pool, i, j, swapAmountIn) = abi.decode(
                args.extraArgs,
                (ICurveCryptoSwap, uint256, uint256, uint256)
            );
            swapAmountOut = _swap(
                args.xPYT,
                swapAmountIn,
                pool,
                i,
                j,
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
    /// Internal utilities
    /// -----------------------------------------------------------------------

    /// @dev Use a Curve V2 pool to swap between two tokens
    /// @param tokenIn The input token
    /// @param tokenAmountIn The token input amount
    /// @param pool The Curve V2 pool to use
    /// @param i The index of the input token in the Curve pool
    /// @param j The index of the output token in the Curve pool
    /// @param recipient The address that will receive the token output
    function _swap(
        ERC20 tokenIn,
        uint256 tokenAmountIn,
        ICurveCryptoSwap pool,
        uint256 i,
        uint256 j,
        address recipient
    ) internal returns (uint256) {
        tokenIn.approveMaxIfNeeded(address(pool), tokenAmountIn);
        return pool.exchange(i, j, tokenAmountIn, 0, recipient);
    }
}
