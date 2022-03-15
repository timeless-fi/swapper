// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {Multicall} from "timeless/lib/Multicall.sol";
import {SelfPermit} from "timeless/lib/SelfPermit.sol";

abstract contract Swapper is Multicall, SelfPermit {
    /// -----------------------------------------------------------------------
    /// Library usage
    /// -----------------------------------------------------------------------

    using SafeTransferLib for ERC20;

    /// -----------------------------------------------------------------------
    /// Errors
    /// -----------------------------------------------------------------------

    error Error_InsufficientOutput();
    error Error_PastDeadline();

    /// -----------------------------------------------------------------------
    /// Structs
    /// -----------------------------------------------------------------------

    struct SwapArgs {
        ERC4626 xPYT;
        uint256 tokenAmountIn;
        uint256 minAmountOut;
        address recipient;
        bool useSwapperBalance;
        uint256 deadline;
        bytes extraArgs;
    }

    /// -----------------------------------------------------------------------
    /// Swaps
    /// -----------------------------------------------------------------------

    function swapUnderlyingToXPYT(SwapArgs calldata args)
        external
        virtual
        returns (uint256 tokenAmountOut);

    function swapUnderlyingToNYT(SwapArgs calldata args)
        external
        virtual
        returns (uint256 tokenAmountOut);

    function swapXPYTToUnderlying(SwapArgs calldata args)
        external
        virtual
        returns (uint256 tokenAmountOut);

    function swapNYTToUnderlying(SwapArgs calldata args)
        external
        virtual
        returns (uint256 tokenAmountOut);

    /// -----------------------------------------------------------------------
    /// 0x support
    /// -----------------------------------------------------------------------

    function do0xSwap() external virtual {}

    /// -----------------------------------------------------------------------
    /// Internal utilities
    /// -----------------------------------------------------------------------

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
