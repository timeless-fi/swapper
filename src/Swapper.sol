// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import {BoringOwnable} from "boringsolidity/BoringOwnable.sol";

import {WETH} from "solmate/tokens/WETH.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ReentrancyGuard} from "solmate/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {Gate} from "timeless/Gate.sol";
import {IxPYT} from "timeless/external/IxPYT.sol";
import {Multicall} from "timeless/lib/Multicall.sol";
import {SelfPermit} from "timeless/lib/SelfPermit.sol";

import {ApproveMaxIfNeeded} from "./lib/ApproveMaxIfNeeded.sol";

/// @title Swapper
/// @author zefram.eth
/// @notice Abstract contract for swapping between xPYTs/NYTs and their underlying asset by
/// swapping via an external DEX and minting/burning xPYT/NYT.
/// @dev Swapper supports two-hop swaps where one of the swaps is an 0x swap between two regular tokens,
/// which enables swapping any supported token into any xPYT/NYT. Two-hop swaps are done by chaining
/// two calls together via Multicall and setting the recipient of the first swap to the Swapper.
/// Note: Swapper should never hold any value (tokens or ETH) except for during a swap. Any leftover value
/// may be stolen. This is by design.
abstract contract Swapper is
    Multicall,
    SelfPermit,
    ReentrancyGuard,
    BoringOwnable
{
    /// -----------------------------------------------------------------------
    /// Library usage
    /// -----------------------------------------------------------------------

    using SafeTransferLib for ERC20;
    using SafeTransferLib for IxPYT;
    using ApproveMaxIfNeeded for ERC20;
    using ApproveMaxIfNeeded for IxPYT;

    /// -----------------------------------------------------------------------
    /// Errors
    /// -----------------------------------------------------------------------

    error Error_SameToken();
    error Error_PastDeadline();
    error Error_ZeroExSwapFailed();
    error Error_InsufficientOutput();
    error Error_ProtocolFeeRecipientIsZero();

    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------

    event SetProtocolFee(ProtocolFeeInfo protocolFeeInfo_);

    /// -----------------------------------------------------------------------
    /// Structs
    /// -----------------------------------------------------------------------

    /// @param gate The Gate used by the xPYT/NYT
    /// @param vault The yield-bearing vault used by the xPYT/NYT
    /// @param underlying The underlying asset of the xPYT/NYT
    /// @param nyt The NYT contract linked to the xPYT/NYT being swapped
    /// @param pyt The PYT contract linked to the xPYT/NYT being swapped
    /// @param xPYT The xPYT contract linked to the xPYT/NYT being swapped
    /// @param tokenAmountIn The amount of token input
    /// @param minAmountOut The minimum acceptable token output amount, used for slippage checking.
    /// @param recipient The recipient of the token output
    /// @param useSwapperBalance Set to true to use the Swapper's token balance as token input, in which
    /// case `tokenAmountIn` will be overriden to the balance.
    /// @param usePYT Set to true to use raw PYT as the input/output token instead of xPYT. Ignored
    /// when swapping from the underlying to NYT.
    /// @param deadline The Unix timestamp (in seconds) after which the call will be reverted
    /// @param extraArgs Used for providing extra input parameters for different protocols/use cases
    struct SwapArgs {
        Gate gate;
        address vault;
        ERC20 underlying;
        ERC20 nyt;
        ERC20 pyt;
        IxPYT xPYT;
        uint256 tokenAmountIn;
        uint256 minAmountOut;
        address recipient;
        bool useSwapperBalance;
        bool usePYT;
        uint256 deadline;
        bytes extraArgs;
    }

    /// @param fee The fee value. Each increment represents 0.01%, so max is 2.55% (8 bits)
    /// @param recipient The address that will receive the protocol fees
    struct ProtocolFeeInfo {
        uint8 fee;
        address recipient;
    }

    /// -----------------------------------------------------------------------
    /// Immutable parameters
    /// -----------------------------------------------------------------------

    /// @notice The 0x proxy contract used for 0x swaps
    address public immutable zeroExProxy;

    /// @notice The Wrapped Ethereum contract
    WETH public immutable weth;

    /// -----------------------------------------------------------------------
    /// Storage variables
    /// -----------------------------------------------------------------------

    /// @notice The protocol fee and the fee recipient address.
    ProtocolFeeInfo public protocolFeeInfo;

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------

    constructor(
        address zeroExProxy_,
        WETH weth_,
        ProtocolFeeInfo memory protocolFeeInfo_
    ) {
        zeroExProxy = zeroExProxy_;
        weth = weth_;

        if (
            protocolFeeInfo_.fee != 0 &&
            protocolFeeInfo_.recipient == address(0)
        ) {
            revert Error_ProtocolFeeRecipientIsZero();
        }
        protocolFeeInfo = protocolFeeInfo_;
        emit SetProtocolFee(protocolFeeInfo_);
    }

    /// -----------------------------------------------------------------------
    /// Swaps
    /// -----------------------------------------------------------------------

    /// @notice Swaps the underlying asset of an NYT into the NYT
    /// @param args The input arguments (see SwapArgs definition)
    /// @return tokenAmountOut The amount of token output
    function swapUnderlyingToNyt(SwapArgs calldata args)
        external
        payable
        virtual
        returns (uint256 tokenAmountOut);

    /// @notice Swaps the underlying asset of an xPYT into the xPYT
    /// @param args The input arguments (see SwapArgs definition)
    /// @return tokenAmountOut The amount of token output
    function swapUnderlyingToXpyt(SwapArgs calldata args)
        external
        payable
        virtual
        returns (uint256 tokenAmountOut);

    /// @notice Swaps an NYT to its underlying asset
    /// @param args The input arguments (see SwapArgs definition)
    /// @return tokenAmountOut The amount of token output
    function swapNytToUnderlying(SwapArgs calldata args)
        external
        payable
        virtual
        returns (uint256 tokenAmountOut);

    /// @notice Swaps an xPYT to its underlying asset
    /// @param args The input arguments (see SwapArgs definition)
    /// @return tokenAmountOut The amount of token output
    function swapXpytToUnderlying(SwapArgs calldata args)
        external
        payable
        virtual
        returns (uint256 tokenAmountOut);

    /// -----------------------------------------------------------------------
    /// 0x support
    /// -----------------------------------------------------------------------

    /// @notice Swaps between two regular tokens using 0x.
    /// @dev Used in conjuction with the 0x API https://www.0x.org/docs/api
    /// @param tokenIn The input token
    /// @param tokenAmountIn The amount of token input
    /// @param tokenOut The output token
    /// @param minAmountOut The minimum acceptable token output amount, used for slippage checking.
    /// @param recipient The recipient of the token output
    /// @param useSwapperBalance Set to true to use the Swapper's token balance as token input
    /// @param requireApproval Set to true to approve tokenIn to zeroExProxy
    /// @param deadline The Unix timestamp (in seconds) after which the call will be reverted
    /// @param swapData The call data to zeroExProxy to execute the swap, obtained from
    /// the https://api.0x.org/swap/v1/quote endpoint
    /// @return tokenAmountOut The amount of token output
    function doZeroExSwap(
        ERC20 tokenIn,
        uint256 tokenAmountIn,
        ERC20 tokenOut,
        uint256 minAmountOut,
        address recipient,
        bool useSwapperBalance,
        bool requireApproval,
        uint256 deadline,
        bytes calldata swapData
    ) external payable virtual nonReentrant returns (uint256 tokenAmountOut) {
        // check if input token equals output
        if (tokenIn == tokenOut) {
            revert Error_SameToken();
        }

        // check deadline
        if (block.timestamp > deadline) {
            revert Error_PastDeadline();
        }

        // transfer in input tokens
        if (!useSwapperBalance) {
            tokenIn.safeTransferFrom(msg.sender, address(this), tokenAmountIn);
        }

        // approve zeroExProxy
        if (requireApproval) {
            tokenIn.safeApprove(zeroExProxy, type(uint256).max);
        }

        // do swap via zeroExProxy
        (bool success, ) = zeroExProxy.call(swapData);
        if (!success) {
            revert Error_ZeroExSwapFailed();
        }

        // check slippage
        tokenAmountOut = tokenOut.balanceOf(address(this));
        if (tokenAmountOut < minAmountOut) {
            revert Error_InsufficientOutput();
        }

        // transfer output tokens to recipient
        if (recipient != address(this)) {
            tokenOut.safeTransfer(recipient, tokenAmountOut);
        }
    }

    /// -----------------------------------------------------------------------
    /// WETH support
    /// -----------------------------------------------------------------------

    /// @notice Wraps the user's ETH input into WETH
    /// @dev Should be used as part of a multicall to convert the user's ETH input into WETH
    /// so that it can be swapped into xPYT/NYT.
    function wrapEthInput() external payable {
        weth.deposit{value: msg.value}();
    }

    /// -----------------------------------------------------------------------
    /// Owner functions
    /// -----------------------------------------------------------------------

    /// @notice Updates the protocol fee and/or the protocol fee recipient.
    /// Only callable by the owner.
    /// @param protocolFeeInfo_ The new protocol fee info
    function ownerSetProtocolFee(ProtocolFeeInfo calldata protocolFeeInfo_)
        external
        virtual
        onlyOwner
    {
        if (
            protocolFeeInfo_.fee != 0 &&
            protocolFeeInfo_.recipient == address(0)
        ) {
            revert Error_ProtocolFeeRecipientIsZero();
        }
        protocolFeeInfo = protocolFeeInfo_;

        emit SetProtocolFee(protocolFeeInfo_);
    }

    /// -----------------------------------------------------------------------
    /// Internal functions
    /// -----------------------------------------------------------------------

    /// @dev Interfaces with the underlying DEX to swap from the underlying to
    /// a yield token.
    /// @param tokenIn The input token
    /// @param tokenAmountIn The token input amount
    /// @param recipient The address that will receive the token output
    /// @param extraArgs Used for providing extra input parameters for different protocols/use cases
    function _swapFromUnderlying(
        ERC20 tokenIn,
        uint256 tokenAmountIn,
        address recipient,
        bytes memory extraArgs
    ) internal virtual returns (uint256 swapAmountOut);

    /// @dev Interfaces with the underlying DEX to swap from a yield token to
    /// the underlying.
    /// @param tokenIn The input token
    /// @param recipient The address that will receive the token output
    /// @param extraArgs Used for providing extra input parameters for different protocols/use cases
    function _swapFromYieldToken(
        ERC20 tokenIn,
        address recipient,
        bytes memory extraArgs
    ) internal virtual returns (uint256 swapAmountIn, uint256 swapAmountOut);

    /// @dev Swaps the underlying asset of an NYT into the NYT
    /// @param args The input arguments (see SwapArgs definition)
    /// @param extraArgs Extra input arguments passed to _swapFromUnderlying()
    /// @return tokenAmountOut The amount of token output
    function _swapUnderlyingToNyt(
        SwapArgs calldata args,
        bytes memory extraArgs
    ) internal virtual returns (uint256 tokenAmountOut) {
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
                    unchecked {
                        tokenAmountIn -= feeAmount;
                    }

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
        // swap and add swap output to result
        tokenAmountOut += _swapFromUnderlying(
            args.xPYT,
            xPYTMinted,
            args.recipient,
            extraArgs
        );

        // check slippage
        if (tokenAmountOut < args.minAmountOut) {
            revert Error_InsufficientOutput();
        }
    }

    /// @dev Swaps the underlying asset of an xPYT into the xPYT
    /// @param args The input arguments (see SwapArgs definition)
    /// @param extraArgs Extra input arguments passed to _swapFromUnderlying()
    /// @return tokenAmountOut The amount of token output
    function _swapUnderlyingToXpyt(
        SwapArgs calldata args,
        bytes memory extraArgs
    ) internal virtual returns (uint256 tokenAmountOut) {
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
                    unchecked {
                        tokenAmountIn -= feeAmount;
                    }

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
        uint256 swapOutput = _swapFromUnderlying(
            args.nyt,
            tokenAmountIn,
            args.usePYT ? address(this) : args.recipient, // set recipient to this when using PYT in order to unwrap xPYT
            extraArgs
        );

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

    /// @dev Swaps an NYT to its underlying asset
    /// @param args The input arguments (see SwapArgs definition)
    /// @param extraArgs Extra input arguments passed to _swapFromYieldToken()
    /// @return tokenAmountOut The amount of token output
    function _swapNytToUnderlying(
        SwapArgs calldata args,
        bytes memory extraArgs
    ) internal virtual returns (uint256 tokenAmountOut) {
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
                unchecked {
                    tokenAmountIn -= feeAmount;
                }

                // transfer fee to recipient
                args.nyt.safeTransfer(protocolFeeInfo_.recipient, feeAmount);
            }
        }

        // swap NYT to xPYT
        (uint256 swapAmountIn, uint256 swapAmountOut) = _swapFromYieldToken(
            args.nyt,
            address(this),
            extraArgs
        );

        // convert swap output xPYT amount into equivalent PYT amount
        swapAmountOut = args.xPYT.convertToAssets(swapAmountOut);

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

    /// @dev Swaps an xPYT to its underlying asset
    /// @param args The input arguments (see SwapArgs definition)
    /// @param extraArgs Extra input arguments passed to _swapFromYieldToken()
    /// @return tokenAmountOut The amount of token output
    function _swapXpytToUnderlying(
        SwapArgs calldata args,
        bytes memory extraArgs
    ) internal virtual returns (uint256 tokenAmountOut) {
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
                unchecked {
                    tokenAmountIn -= feeAmount;
                }

                // transfer fee to recipient
                args.xPYT.safeTransfer(protocolFeeInfo_.recipient, feeAmount);
            }
        }

        // swap xPYT to NYT
        (uint256 swapAmountIn, uint256 swapAmountOut) = _swapFromYieldToken(
            args.xPYT,
            address(this),
            extraArgs
        );

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
}
