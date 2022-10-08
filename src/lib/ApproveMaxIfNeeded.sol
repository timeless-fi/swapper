// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

/// @title ApproveMaxIfNeeded
/// @author zefram.eth
/// @notice Gives max ERC20 approval to the spender if the current allowance is insufficient.
library ApproveMaxIfNeeded {
    using SafeTransferLib for ERC20;

    function approveMaxIfNeeded(
        ERC20 token,
        address spender,
        uint256 neededAmount
    ) internal {
        uint256 allowance = token.allowance(address(this), spender);
        if (allowance < neededAmount) {
            // need more allowance
            // call approve
            token.safeApprove(spender, type(uint256).max);
        }
    }
}
