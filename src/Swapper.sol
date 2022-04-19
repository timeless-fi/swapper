// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {ReentrancyGuard} from "solmate/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {Gate} from "timeless/Gate.sol";
import {IxPYT} from "timeless/external/IxPYT.sol";
import {Multicall} from "timeless/lib/Multicall.sol";
import {SelfPermit} from "timeless/lib/SelfPermit.sol";

/// @title Swapper
/// @author zefram.eth
/// @notice Abstract contract for swapping between xPYTs/NYTs and their underlying asset by
/// swapping via an external DEX and minting/burning xPYT/NYT.
/// @dev Swapper supports two-hop swaps where one of the swaps is an 0x swap between two regular tokens,
/// which enables swapping any supported token into any xPYT/NYT. Two-hop swaps are done by chaining
/// two calls together via Multicall and setting the recipient of the first swap to the Swapper.
abstract contract Swapper is Multicall, SelfPermit, ReentrancyGuard {
    /// -----------------------------------------------------------------------
    /// Library usage
    /// -----------------------------------------------------------------------

    using SafeTransferLib for ERC20;

    /// -----------------------------------------------------------------------
    /// Errors
    /// -----------------------------------------------------------------------

    error Error_PastDeadline();
    error Error_ZeroExSwapFailed();
    error Error_InsufficientOutput();

    /// -----------------------------------------------------------------------
    /// Structs
    /// -----------------------------------------------------------------------

    /// @param gate The Gate used by the xPYT/NYT
    /// @param vault The yield-bearing vault used by the xPYT/NYT
    /// @param underlying The underlying asset of the xPYT/NYT
    /// @param nyt The NYT contract linked to the xPYT/NYT being swapped
    /// @param xPYT The xPYT contract linked to the xPYT/NYT being swapped
    /// @param tokenAmountIn The amount of token input
    /// @param minAmountOut The minimum acceptable token output amount, used for slippage checking.
    /// @param recipient The recipient of the token output
    /// @param useSwapperBalance Set to true to use the Swapper's token balance as token input, in which
    /// case `tokenAmountIn` will be overriden to the balance.
    /// @param deadline The Unix timestamp (in seconds) after which the call will be reverted
    /// @param extraArgs Used for providing extra input parameters for different protocols/use cases
    struct SwapArgs {
        Gate gate;
        address vault;
        ERC20 underlying;
        ERC20 nyt;
        IxPYT xPYT;
        uint256 tokenAmountIn;
        uint256 minAmountOut;
        address recipient;
        bool useSwapperBalance;
        uint256 deadline;
        bytes extraArgs;
    }

    /// -----------------------------------------------------------------------
    /// Immutable parameters
    /// -----------------------------------------------------------------------

    address public immutable zeroExProxy;

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------

    constructor(address zeroExProxy_) {
        zeroExProxy = zeroExProxy_;
    }

    /// -----------------------------------------------------------------------
    /// Swaps
    /// -----------------------------------------------------------------------

    /// @notice Swaps the underlying asset of an NYT into the NYT
    /// @param args The input arguments (see SwapArgs definition)
    /// @return tokenAmountOut The amount of token output
    function swapUnderlyingToNyt(SwapArgs calldata args)
        external
        virtual
        returns (uint256 tokenAmountOut);

    /// @notice Swaps the underlying asset of an xPYT into the xPYT
    /// @param args The input arguments (see SwapArgs definition)
    /// @return tokenAmountOut The amount of token output
    function swapUnderlyingToXpyt(SwapArgs calldata args)
        external
        virtual
        returns (uint256 tokenAmountOut);

    /// @notice Swaps an NYT to its underlying asset
    /// @param args The input arguments (see SwapArgs definition)
    /// @return tokenAmountOut The amount of token output
    function swapNytToUnderlying(SwapArgs calldata args)
        external
        virtual
        returns (uint256 tokenAmountOut);

    /// @notice Swaps an xPYT to its underlying asset
    /// @param args The input arguments (see SwapArgs definition)
    /// @return tokenAmountOut The amount of token output
    function swapXpytToUnderlying(SwapArgs calldata args)
        external
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
    ) external virtual nonReentrant returns (uint256 tokenAmountOut) {
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
}
