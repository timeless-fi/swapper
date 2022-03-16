// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";

import {Gate} from "timeless/Gate.sol";
import {Factory} from "timeless/Factory.sol";
import {YearnGate} from "timeless/gates/YearnGate.sol";
import {NegativeYieldToken} from "timeless/NegativeYieldToken.sol";
import {PerpetualYieldToken} from "timeless/PerpetualYieldToken.sol";

import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3MintCallback} from "v3-core/interfaces/callback/IUniswapV3MintCallback.sol";

import {Swapper} from "../Swapper.sol";
import {TickMath} from "./lib/TickMath.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {PoolAddress} from "../lib/PoolAddress.sol";
import {TestERC4626} from "./mocks/TestERC4626.sol";
import {BaseTest, console} from "./base/BaseTest.sol";
import {UniswapV3Swapper} from "../UniswapV3Swapper.sol";
import {TestYearnVault} from "./mocks/TestYearnVault.sol";
import {UniswapDeployer} from "./utils/UniswapDeployer.sol";
import {LiquidityAmounts} from "./lib/LiquidityAmounts.sol";

contract UniswapV3SwapperTest is
    BaseTest,
    UniswapDeployer,
    IUniswapV3MintCallback
{
    error Error_NotUniswapV3Pool();

    address constant recipient = address(0x42);
    address constant protocolFeeRecipient = address(0x6969);

    uint256 constant PROTOCOL_FEE = 100; // 10%
    uint24 constant UNI_FEE = 500;
    uint8 constant DECIMALS = 18;
    uint256 constant ONE = 10**DECIMALS;
    uint256 constant AMOUNT = 100 * ONE;

    Factory factory;
    Gate gate;
    TestERC20 underlying;
    address vault;
    NegativeYieldToken nyt;
    PerpetualYieldToken pyt;
    ERC4626 xPYT;
    IUniswapV3Factory uniswapV3Factory;
    IUniswapV3Pool uniswapV3Pool;
    Swapper swapper;

    function setUp() public {
        // deploy factory
        factory = new Factory(
            address(this),
            Factory.ProtocolFeeInfo({
                fee: uint8(PROTOCOL_FEE),
                recipient: protocolFeeRecipient
            })
        );

        // deploy gate
        gate = new YearnGate(factory);

        // deploy underlying
        underlying = new TestERC20(DECIMALS);

        // deploy vault
        vault = address(new TestYearnVault(underlying));

        // deploy PYT & NYT
        (nyt, pyt) = factory.deployYieldTokenPair(gate, vault);

        // deploy xPYT
        xPYT = new TestERC4626(ERC20(address(pyt)));

        // deploy uniswap v3 factory
        uniswapV3Factory = IUniswapV3Factory(deployUniswapV3Factory());

        // deploy uniswap v3 pair
        uniswapV3Pool = IUniswapV3Pool(
            uniswapV3Factory.createPool(address(nyt), address(xPYT), UNI_FEE)
        );
        uniswapV3Pool.initialize(TickMath.getSqrtRatioAtTick(0));

        // mint underlying
        underlying.mint(address(this), 4 * AMOUNT);

        // mint xPYT & NYT
        underlying.approve(address(gate), type(uint256).max);
        gate.enterWithUnderlying(
            address(this),
            address(this),
            vault,
            xPYT,
            2 * AMOUNT
        );

        // give some yield to xPYT
        gate.enterWithUnderlying(
            address(this),
            address(xPYT),
            vault,
            ERC4626(address(0)),
            AMOUNT
        );

        // add liquidity
        (address token0, address token1) = address(nyt) < address(xPYT)
            ? (address(nyt), address(xPYT))
            : (address(xPYT), address(nyt));
        _addLiquidity(
            AddLiquidityParams({
                token0: token0,
                token1: token1,
                fee: UNI_FEE,
                recipient: address(this),
                tickLower: -10000,
                tickUpper: 10000,
                amount0Desired: AMOUNT,
                amount1Desired: AMOUNT,
                amount0Min: 0,
                amount1Min: 0
            })
        );

        // deploy swapper
        swapper = new UniswapV3Swapper(address(uniswapV3Factory));

        // set token approvals
        underlying.approve(address(swapper), type(uint256).max);
        nyt.approve(address(swapper), type(uint256).max);
        xPYT.approve(address(swapper), type(uint256).max);

        // token balances:
        // underlying: AMOUNT
        // xPYT: AMOUNT
        // NYT: 2 * AMOUNT
    }

    function testBasic_swapUnderlyingToXPYT() public {
        uint256 tokenAmountIn = AMOUNT / 10;
        Swapper.SwapArgs memory args = Swapper.SwapArgs({
            gate: gate,
            vault: vault,
            underlying: underlying,
            nyt: ERC20(address(nyt)),
            xPYT: xPYT,
            tokenAmountIn: tokenAmountIn,
            minAmountOut: 0,
            recipient: recipient,
            useSwapperBalance: false,
            deadline: block.timestamp,
            extraArgs: abi.encode(UNI_FEE)
        });
        uint256 tokenAmountOut = swapper.swapUnderlyingToXPYT(args);

        assertGtDecimal(tokenAmountOut, 0, DECIMALS, "tokenAmountOut is zero");
        assertEqDecimal(
            underlying.balanceOf(address(this)),
            AMOUNT - tokenAmountIn,
            DECIMALS,
            "underlying balance of address(this) incorrect"
        );
        assertEqDecimal(
            underlying.balanceOf(address(swapper)),
            0,
            DECIMALS,
            "swapper has non-zero underlying"
        );
        assertEqDecimal(
            nyt.balanceOf(address(swapper)),
            0,
            DECIMALS,
            "swapper has non-zero NYT"
        );
        assertEqDecimal(
            xPYT.balanceOf(address(swapper)),
            0,
            DECIMALS,
            "swapper has non-zero xPYT"
        );
        assertEqDecimal(
            xPYT.balanceOf(recipient),
            tokenAmountOut,
            DECIMALS,
            "recipient didn't get token output"
        );
    }

    function testBasic_swapUnderlyingToNYT() public {
        uint256 tokenAmountIn = AMOUNT / 10;
        Swapper.SwapArgs memory args = Swapper.SwapArgs({
            gate: gate,
            vault: vault,
            underlying: underlying,
            nyt: ERC20(address(nyt)),
            xPYT: xPYT,
            tokenAmountIn: tokenAmountIn,
            minAmountOut: 0,
            recipient: recipient,
            useSwapperBalance: false,
            deadline: block.timestamp,
            extraArgs: abi.encode(UNI_FEE)
        });
        uint256 tokenAmountOut = swapper.swapUnderlyingToNYT(args);

        assertGtDecimal(tokenAmountOut, 0, DECIMALS, "tokenAmountOut is zero");
        assertEqDecimal(
            underlying.balanceOf(address(this)),
            AMOUNT - tokenAmountIn,
            DECIMALS,
            "underlying balance of address(this) incorrect"
        );
        assertEqDecimal(
            underlying.balanceOf(address(swapper)),
            0,
            DECIMALS,
            "swapper has non-zero underlying"
        );
        assertEqDecimal(
            nyt.balanceOf(address(swapper)),
            0,
            DECIMALS,
            "swapper has non-zero NYT"
        );
        assertEqDecimal(
            xPYT.balanceOf(address(swapper)),
            0,
            DECIMALS,
            "swapper has non-zero xPYT"
        );
        assertEqDecimal(
            nyt.balanceOf(recipient),
            tokenAmountOut,
            DECIMALS,
            "recipient didn't get token output"
        );
    }

    /// -----------------------------------------------------------------------
    /// Uniswap V3 add liquidity support
    /// -----------------------------------------------------------------------

    struct MintCallbackData {
        PoolAddress.PoolKey poolKey;
        address payer;
    }

    /// @inheritdoc IUniswapV3MintCallback
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external override {
        MintCallbackData memory decoded = abi.decode(data, (MintCallbackData));
        address pool = PoolAddress.computeAddress(
            address(uniswapV3Factory),
            decoded.poolKey
        );
        if (msg.sender != address(pool)) {
            revert Error_NotUniswapV3Pool();
        }

        if (amount0Owed > 0)
            _pay(
                ERC20(decoded.poolKey.token0),
                decoded.payer,
                msg.sender,
                amount0Owed
            );
        if (amount1Owed > 0)
            _pay(
                ERC20(decoded.poolKey.token1),
                decoded.payer,
                msg.sender,
                amount1Owed
            );
    }

    struct AddLiquidityParams {
        address token0;
        address token1;
        uint24 fee;
        address recipient;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
    }

    /// @notice Add liquidity to an initialized pool
    function _addLiquidity(AddLiquidityParams memory params)
        internal
        returns (
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1,
            IUniswapV3Pool pool
        )
    {
        PoolAddress.PoolKey memory poolKey = PoolAddress.PoolKey({
            token0: params.token0,
            token1: params.token1,
            fee: params.fee
        });

        pool = IUniswapV3Pool(
            PoolAddress.computeAddress(address(uniswapV3Factory), poolKey)
        );

        // compute the liquidity amount
        {
            (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
            uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(
                params.tickLower
            );
            uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(
                params.tickUpper
            );

            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                sqrtRatioAX96,
                sqrtRatioBX96,
                params.amount0Desired,
                params.amount1Desired
            );
        }

        (amount0, amount1) = pool.mint(
            params.recipient,
            params.tickLower,
            params.tickUpper,
            liquidity,
            abi.encode(
                MintCallbackData({poolKey: poolKey, payer: address(this)})
            )
        );

        require(
            amount0 >= params.amount0Min && amount1 >= params.amount1Min,
            "Price slippage check"
        );
    }

    /// @dev Pays tokens to the recipient using the payer's balance
    /// @param token The token to pay
    /// @param payer The address that will pay the tokens
    /// @param recipient_ The address that will receive the tokens
    /// @param value The amount of tokens to pay
    function _pay(
        ERC20 token,
        address payer,
        address recipient_,
        uint256 value
    ) internal {
        if (payer == address(this)) {
            // pay with tokens already in the contract
            token.transfer(recipient_, value);
        } else {
            // pull payment
            token.transferFrom(payer, recipient_, value);
        }
    }
}
